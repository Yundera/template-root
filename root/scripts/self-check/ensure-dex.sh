#!/bin/bash
# ensure-dex.sh - Provision the Dex OIDC broker (the PCS SSO identity provider).
#
# Responsibilities (all idempotent):
#   - render Dex config.yaml from the template every run (tracks DOMAIN changes
#     and re-emits the connector secrets),
#   - read the Dex<->Authelia connector secret (AUTHELIA_DEX_SECRET, minted by
#     ensure-authelia.sh) so the Local Account connector renders,
#   - concatenate any drop-in connectors from dex/connectors.d/*.yaml,
#   - own the sqlite data dir so the dex container (uid 1001) can write dex.db,
#   - restart dex so a re-rendered config is picked up.
#
# Dex is a pure BROKER: it holds no local credential of its own. The local
# account lives in Authelia (the "Local Account" connector, see
# ensure-authelia.sh); the old enablePasswordDB break-glass admin has been
# removed. Interactive login is therefore always federated to a connector.
#
# Dex reads exactly ONE config file — it has no include/conf.d mechanism of its
# own (verified against v2.45.1: `cobra.ExactArgs(1)`, single ReadFile +
# Unmarshal). connectors.d/ below is how this template provides that anyway, and
# it is the ONLY way a connector gets added: "Yundera Login" is written by
# ensure-yundera-login.sh, and only "Local Account" is still rendered inline
# here (it is the one connector whose secret this script already holds).
#
# The `casaos` connector (and the BRIDGE_SECRET it consumed) is gone: Authelia is
# the PCS-local credential now, and casaos-oidc-bridge died with it. The stale
# BRIDGE_SECRET and /DATA/AppData/yundera/casaos-oidc-bridge are swept by
# scripts/migrations/2026-07-31-15-drop-casaos-oidc.sh.
#
# Storage layout (host /DATA/AppData/yundera/):
#   dex/config.yaml          rendered Dex config (re-rendered each run)
#   dex/connectors.d/*.yaml  drop-in connectors, concatenated into config.yaml
#   dex/dex.db               Dex sqlite store (clients, codes, refresh tokens, keys)
#
# RECOVERY / BACKUP: none of this needs backing up — it is all CACHE.
#   - The auth-registrar (mesh-auth) is STATELESS: its OIDC client-secret cache
#     lives inside the container (DEX_CLIENTS_DIR=/tmp/dex-clients), never on the
#     data volume. On restart it transparently rotates each client's secret on
#     the next /register.
#   - dex.db is rebuilt automatically on loss. Apps re-register on their next
#     login (the AppShield/hash-lock sidecars hold no persisted creds), and users
#     simply log in again (Dex regenerates its signing keys, invalidating old
#     tokens). Deleting /DATA/AppData/yundera/dex is therefore safe — this script
#     reconstructs config.yaml and the rest self-heals through normal logins.
#   - ONE EXCEPTION: connectors.d/ (below) is not cache. It is whatever the
#     deployment dropped in, and nothing here regenerates it. Wiping the dex dir
#     silently removes those connectors from the login page.
#
# NETWORK: Dex's gRPC client-management API is UNAUTHENTICATED, so the rendered
# config binds it to a static IP (172.31.7.2) on the isolated `dex-internal`
# docker network instead of 0.0.0.0. Only auth-registrar sits on that network;
# app containers (pcs network only) cannot reach gRPC. The IP is pinned in both
# docker-compose.yml and dex.config.yaml.tmpl — keep them in sync.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

DEX_ROOT="/DATA/AppData/yundera/dex"
TEMPLATE="$YND_ROOT/dex.config.yaml.tmpl"
CONFIG_OUT="$DEX_ROOT/config.yaml"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

# ghcr.io/dexidp/dex runs as uid/gid 1001 and must own its sqlite tree.
DEX_UID=1001

mkdir -p "$DEX_ROOT"

DOMAIN="$("$ENV_MGR" get DOMAIN "$USER_ENV")"
if [ -z "$DOMAIN" ]; then
    log_error "DOMAIN not set in $USER_ENV; cannot render Dex config"
    exit 1
fi

# Dex<->Authelia connector secret for the "Local Account" connector. Generated
# and hashed by ensure-authelia.sh (which runs just before this script) and
# persisted in .pcs.secret.env; read it back here so the connector's plaintext
# clientSecret renders into config.yaml. Empty is tolerated (the connector then
# renders with an empty secret and simply fails its back-channel until Authelia
# has provisioned) so a partial cycle never aborts Dex.
AUTHELIA_DEX_SECRET="$("$ENV_MGR" get AUTHELIA_DEX_SECRET "$SECRET_ENV")"
if [ -z "$AUTHELIA_DEX_SECRET" ]; then
    log_warn "AUTHELIA_DEX_SECRET not set yet; Local Account connector will render without a secret until ensure-authelia.sh has run"
fi

# Render config.yaml. All tokens are envsubst-safe (no '$'-bearing values), so a
# single envsubst pass suffices.
TMP="$(mktemp)"
chmod 600 "$TMP"
# Encrypts Dex's own session cookie (see the `sessions:` block in the template).
# Minted by ensure-dex-session-key.sh, which scripts-config.txt orders before
# this script. Empty is tolerated: Dex starts and sessions still work, the cookie
# is simply not encrypted — so a missing key degrades rather than breaking login.
DEX_SESSION_KEY="$("$ENV_MGR" get DEX_SESSION_KEY "$SECRET_ENV")"
if [ -z "$DEX_SESSION_KEY" ]; then
    log_warn "DEX_SESSION_KEY not set yet; Dex session cookies will be unencrypted until ensure-dex-session-key.sh has run"
fi

export DOMAIN AUTHELIA_DEX_SECRET DEX_SESSION_KEY
envsubst '${DOMAIN} ${AUTHELIA_DEX_SECRET} ${DEX_SESSION_KEY}' < "$TEMPLATE" > "$TMP"
mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"
log_info "Rendered Dex config at $CONFIG_OUT"

# Tracks whether anything at all ended up under `connectors:` — see the
# never-empty check at the end of this script.
CONNECTOR_COUNT=0

# ---------------------------------------------------------------------------
# Local Account connector — Authelia — ONLY when the account is claimed.
#
# A fresh PCS seeds its owner account `disabled: true` (ensure-authelia.sh), and
# Authelia refuses a disabled user as "user not found" — so offering the button
# before onboarding shows a login that cannot possibly work. Claimed-ness is
# therefore the render condition, and it is read straight from the user store:
# at least one user that is not disabled.
#
# FAIL-OPEN on any doubt (yq missing, unreadable file, malformed YAML): render
# the connector. Guessing "unclaimed" on a box that is actually claimed would
# hide the owner's only door; guessing "claimed" on a fresh box merely restores
# the old cosmetic wart. The asymmetry is deliberate.
# ---------------------------------------------------------------------------
USERS_DB="/DATA/AppData/yundera/auth/users_database.yml"
LOCAL_ACCOUNT_CLAIMED=1
if [ -f "$USERS_DB" ] && command -v yq >/dev/null 2>&1; then
    if ENABLED="$(yq -e '[.users[] | select(.disabled != true)] | length' "$USERS_DB" 2>/dev/null)"; then
        [ "$ENABLED" -gt 0 ] 2>/dev/null || LOCAL_ACCOUNT_CLAIMED=0
    fi
fi

if [ "$LOCAL_ACCOUNT_CLAIMED" = "1" ]; then
    cat >> "$CONFIG_OUT" <<YAML
  # Local Account — Authelia, the PCS-local credential store (replaces reliance
  # on CasaOS). Publicly-trusted host so Dex's back-channel TLS validates against
  # system roots. Authelia's own login page carries the password-reset link.
  - type: oidc
    id: authelia
    name: Local Account
    config:
      issuer: https://local-auth-${DOMAIN}
      clientID: dex
      clientSecret: "${AUTHELIA_DEX_SECRET}"
      # Dex's own connector callback.
      redirectURI: https://auth-${DOMAIN}/callback
      # Authelia 4.39 returns scope claims (preferred_username, email, name) from
      # its userinfo endpoint rather than in the ID token, so Dex must fetch it.
      getUserInfo: true
      userNameKey: preferred_username
      # Group membership drives authorization in the PCS admin dashboard: the
      # \`admins\` group in users_database.yml becomes role=admin in the session
      # (settings-center-app, callback.ts deriveRole), which is what gates every
      # panel and every /api/admin route. Without these two settings the claim
      # never arrives and EVERY local account is treated as a plain user.
      #
      # "insecure" is about staleness, not exposure: Dex only refreshes group
      # claims when the ID token is refreshed, so promoting or demoting a user
      # does not take effect until they log in again.
      insecureEnableGroups: true
      scopes:
        - openid
        - profile
        - email
        - groups
YAML
    CONNECTOR_COUNT=$((CONNECTOR_COUNT + 1))
else
    log_info "Local account is unclaimed; omitting the Local Account connector until onboarding completes"
fi

# ---------------------------------------------------------------------------
# Drop-in connectors — /DATA/AppData/yundera/dex/connectors.d/*.yaml
#
# A generic extension point, deliberately shaped like Authelia's clients.d/*.yml:
# a deployment can federate Dex to something this template does not ship without
# the template knowing anything about it. Each file holds one or more items for
# the `connectors:` block, indented two spaces to match the template:
#
#     - type: oidc
#       id: example
#       name: Example
#       config:
#         issuer: https://example-${DOMAIN}
#         ...
#
# The directory lives in the runtime data dir, NOT the template tree, so
# ensure-template-sync.sh's rsync never touches it and a drop-in survives
# updates. Concatenated onto the freshly-rendered config, which is rewritten
# from scratch each run — so this never accumulates duplicates.
#
# ${DOMAIN} is the only token expanded, letting a drop-in reference the PCS
# domain without knowing it at write time. Anything else ($-bearing secrets in
# particular) passes through verbatim.
#
# NOT VALIDATED, deliberately — this runs before Dex sees the file, and a
# schema check here would be a second, drifting copy of Dex's own.
#
# THE COST IS HIGH, so read this before adding one. Dex resolves every oidc
# connector's discovery document AT STARTUP and treats a failure as fatal:
#
#   failed to initialize server: server: Failed to open connector demo:
#   failed to get provider: 502 Bad Gateway
#
# and the process exits. A drop-in pointing at an issuer that is down, slow to
# boot, or not yet routed by Caddy therefore takes down ALL interactive login on
# this PCS — every other connector included, not just itself. Whatever writes a
# drop-in must confirm the issuer answers over its public URL first, and must
# REMOVE its file rather than leave a stale one behind when it cannot. See
# ensure-yundera-login.sh — the in-tree example of both rules.
# A malformed drop-in does the same thing via a YAML parse error.
#
# Two more rules: keep the shape above, and never reuse a connector id that is
# already taken — `authelia` (rendered above) and `yundera`
# (ensure-yundera-login.sh) — Dex rejects duplicate ids at startup.
# ---------------------------------------------------------------------------
CONNECTORS_D="$DEX_ROOT/connectors.d"
mkdir -p "$CONNECTORS_D"
shopt -s nullglob
for dropin in "$CONNECTORS_D"/*.yaml "$CONNECTORS_D"/*.yml; do
    printf '\n' >> "$CONFIG_OUT"
    envsubst '${DOMAIN}' < "$dropin" >> "$CONFIG_OUT"
    CONNECTOR_COUNT=$((CONNECTOR_COUNT + 1))
    log_info "Added drop-in Dex connector from $(basename "$dropin")"
done
shopt -u nullglob

# Provision the custom Dex frontend (theme + overlaid templates) into the dir the
# compose file bind-mounts over the stock image. Copied every run so template
# updates propagate. Source ships in the template at dex-theme/; a missing source
# just leaves Dex on its stock UI.
THEME_SRC="$YND_ROOT/dex-theme"
DEX_FRONTEND="/DATA/AppData/yundera/dex-frontend"
if [ -d "$THEME_SRC" ]; then
    mkdir -p "$DEX_FRONTEND/templates" "$DEX_FRONTEND/themes"
    cp -f "$THEME_SRC/templates/"*.html "$DEX_FRONTEND/templates/" 2>/dev/null || true
    rm -rf "$DEX_FRONTEND/themes/yundera"
    cp -rf "$THEME_SRC/themes/yundera" "$DEX_FRONTEND/themes/" 2>/dev/null || true
    log_info "Provisioned custom Dex frontend at $DEX_FRONTEND"
else
    log_warn "dex-theme/ not found in template; Dex will use its stock login UI"
fi

# ---------------------------------------------------------------------------
# Never-empty check.
#
# Not a gate — the config is already written and Dex starts fine with an empty
# connector list. This exists so the state is OBVIOUS in yundera.log instead of
# being reverse-engineered from a login page with no buttons.
#
# Reaching zero means: the local account is still unclaimed AND no drop-in
# supplied a connector either (typically ensure-yundera-login.sh finding no
# OPERATOR_API / USER_JWT, or the IdP refusing to register a client).
# Nobody can log in interactively. The way out is the Yundera support key, which
# is SSH and therefore independent of this entire chain — ensure-support-key.sh
# re-asserts it every tick and provisioning aborts without it:
#
#     ssh admin@<host>
#     sudo /DATA/AppData/casaos/apps/yundera/scripts/tools/authelia-user-manager.sh claim <username>
# ---------------------------------------------------------------------------
if [ "$CONNECTOR_COUNT" -eq 0 ]; then
    log_warn "Dex rendered with NO connectors — interactive login is impossible on this PCS."
    log_warn "  Cause: local account unclaimed and no drop-in connector present."
    log_warn "  Fix over SSH: sudo $YND_ROOT/scripts/tools/authelia-user-manager.sh claim <username>"
fi

# Perms: dex (uid 1001) owns its tree so it can create dex.db.
chown -R "$DEX_UID:$DEX_UID" "$DEX_ROOT" 2>/dev/null || true
chmod 755 "$DEX_ROOT" 2>/dev/null || true

# Pick up the re-rendered config if Dex is already running. A mounted-file change
# does not trigger a compose recreate, so an explicit restart is needed. Silent
# on cold boot when the container does not exist yet.
if docker inspect dex >/dev/null 2>&1; then
    docker restart dex >/dev/null 2>&1 || true
fi

log_info "Dex provisioning complete (data root: $DEX_ROOT)"
