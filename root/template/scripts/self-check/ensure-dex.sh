#!/bin/bash
# ensure-dex.sh - Provision the Dex OIDC broker (the PCS SSO identity provider).
#
# Responsibilities (all idempotent):
#   - render Dex config.yaml from the template every run (tracks DOMAIN changes
#     and re-emits the connector secrets),
#   - read the Dex<->Authelia connector secret (AUTHELIA_DEX_SECRET, minted by
#     ensure-authelia.sh) so the Local Account connector renders,
#   - mint DEX_SESSION_KEY, the AES key for Dex's own session cookie,
#   - concatenate any drop-in connectors from dex/connectors.d/*.yaml,
#   - own the sqlite data dir so the dex container (uid 1001) can write dex.db,
#   - restart dex so a re-rendered config is picked up.
#
# Dex is a pure BROKER: it holds no local credential of its own. Interactive
# login is always federated to a connector — see doc/auth-history.md for how the
# stack got that shape, and for the connector ids that are retired but still
# reserved.
#
# Dex reads exactly ONE config file — it has no include/conf.d mechanism of its
# own (verified against v2.45.1: `cobra.ExactArgs(1)`, single ReadFile +
# Unmarshal). connectors.d/ below is how this template provides that anyway, and
# it is the ONLY way a connector gets added: "Yundera Login" is written by
# ensure-yundera-login.sh, and only "Local Account" is still rendered inline
# here (it is the one connector whose secret this script already holds).
#
# Storage layout (host /DATA/AppData/yundera/):
#   dex/config.yaml          rendered Dex config (re-rendered each run)
#   dex/connectors.d/*.yaml  drop-in connectors, concatenated into config.yaml
#   dex/dex.db               Dex sqlite store (clients, codes, refresh tokens, keys)
#   dex/frontend/            rendered login theme + overlaid templates, bind-mounted
#                            over the stock image (tools/provision-dex-frontend.sh)
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
#   - AND ONE ORDERING RULE, since frontend/ moved in here: a `rm -rf dex/` must
#     be followed by tools/provision-dex-frontend.sh BEFORE any `docker compose
#     up`, or Docker recreates frontend/templates/{login,header}.html as
#     DIRECTORIES and dex never starts again. Both in-tree callers already do
#     this in the right order; a hand-run wipe over SSH does not.
#
# NETWORK: Dex's gRPC client-management API is UNAUTHENTICATED, so the rendered
# config binds it to `dex-grpc:5557` — a network-scoped alias on the isolated
# `yundera-auth` docker network — instead of 0.0.0.0. Only auth-registrar sits on
# that network; app containers (pcs network only) cannot reach gRPC. The alias is
# declared in docker-compose.yml and consumed in dex.config.yaml.tmpl — keep the
# two in sync. It is an alias rather than a pinned address on purpose; see the
# note on the dex service in docker-compose.yml.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/secrets.sh"

DEX_ROOT="/DATA/AppData/yundera/dex"
TEMPLATE="$YND_TEMPLATE/dex.config.yaml.tmpl"
CONFIG_OUT="$DEX_ROOT/config.yaml"
# Drop-in connectors, consumed near the end of this script. Declared here because
# the Local Account retention rule below needs to know whether ANY other
# connector will be rendered this cycle.
CONNECTORS_D="$DEX_ROOT/connectors.d"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"

# ghcr.io/dexidp/dex runs as uid/gid 1001 and must own its sqlite tree.
DEX_UID=1001

mkdir -p "$DEX_ROOT"
mkdir -p "$CONNECTORS_D"

# ---------------------------------------------------------------------------
# State from the PREVIOUS cycle, read BEFORE the render below overwrites it.
#
# `LOCAL_ACCOUNT_WAS_RENDERED` is what lets the probe further down distinguish
# "this connector has never worked here" from "this connector worked yesterday
# and the back-channel is merely unavailable at this instant". Those two deserve
# opposite answers, and the old code gave them the same one.
#
# `OTHER_CONNECTOR_PRESENT` keeps the original safety property: Dex exits if
# EVERY connector fails to open, so a connector is only ever retained on a box
# that has another one to fall back on.
# ---------------------------------------------------------------------------
LOCAL_ACCOUNT_WAS_RENDERED=0
if [ -f "$CONFIG_OUT" ] && grep -qE '^[[:space:]]*id:[[:space:]]*authelia[[:space:]]*$' "$CONFIG_OUT"; then
    LOCAL_ACCOUNT_WAS_RENDERED=1
fi

OTHER_CONNECTOR_PRESENT=0
shopt -s nullglob
for dropin in "$CONNECTORS_D"/*.yaml "$CONNECTORS_D"/*.yml; do
    OTHER_CONNECTOR_PRESENT=1
    break
done
shopt -u nullglob

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
#
# AES, and Dex accepts ONLY 16, 24 or 32 BYTES (AES-128/192/256). That is a byte
# length, not a string format: `openssl rand -hex 32` is 64 characters and is
# REJECTED. Base64 of 24 bytes is exactly 32 characters, and carries no '=' and
# no '$', so it also survives the envsubst pass below unchanged.
#
# Minted here rather than in a script of its own: nothing else on the box
# consumes it, nothing in docker-compose.yml interpolates it, and it reaches Dex
# only through the config rendered a few lines down.
DEX_SESSION_KEY=""
ensure_secret DEX_SESSION_KEY openssl rand -base64 24 \
    || log_warn "Could not mint DEX_SESSION_KEY; Dex session cookies will be unencrypted"

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

# ---------------------------------------------------------------------------
# Second render condition: will Dex actually be able to OPEN this connector?
#
# The connector's issuer is https://local-auth-${DOMAIN}, and the dex service
# pins that name to host-gateway (see docker-compose.yml) so the back-channel
# stays on the box instead of hairpinning out through Cloudflare and back. The
# price of the pin is that TLS now terminates at our own Caddy, on a mesh-router
# CA certificate — so the connector only works once mesh-router-agent has
# written data/ca/ca-cert.pem, which the dex container mounts.
#
# FAIL-CLOSED for a connector this box has never rendered, because the asymmetry
# runs the other way from the claimed-ness check above:
#
#   * Rendering a connector Dex cannot open costs the Local Account button
#     anyway (Dex logs "Failed to open connector" and drops it) — and if it is
#     the ONLY connector, Dex exits instead of starting at all.
#   * Omitting it costs the same button, with no chance of taking Dex down.
#
# Both lose the button; only one can lose the box. So omit when in doubt.
#
# BUT NOT FOR ONE THAT ALREADY WORKED HERE — see the retention rule at the end
# of the probe. This comment used to claim the cost was "one self-check cycle,
# the next tick re-probes and re-renders, nothing needs a human", and that claim
# was false for any probe failure with a DETERMINISTIC cause. The cause that bit
# us was the script order itself: ensure-authelia.sh restarted Authelia and
# returned without waiting, this probe fired 1-2s later, and the box lost its
# local login every night for a week (wisera, 2026-09-28) while the log
# faithfully repeated a warning that promised self-recovery.
#
# Two changes follow from that, and they are independent on purpose:
#   1. the probe RETRIES, so a slow restart is not read as a broken service
#      (ensure-authelia.sh also waits now — belt and braces, because a probe
#      that only works when its dependency is punctual is the bug, not the fix);
#   2. a connector a PREVIOUS cycle rendered is RETAINED when the probe fails,
#      as long as another connector exists to keep Dex startable.
#
# The probe is a real discovery fetch over the pinned path — the same route the
# dex container will take (127.0.0.1:443 here, host-gateway:443 there; both are
# Caddy's published port) validated against the same CA file.
#
# NOTE the path split: the CA lives under YND_ROOT (runtime data written by the
# agent), not YND_TEMPLATE (synced tree).
# ---------------------------------------------------------------------------
CA_CERT="$YND_ROOT/data/ca/ca-cert.pem"

# The probe RETRIES. A single shot made this check a race against the previous
# script in scripts-config.txt: ensure-authelia.sh restarts Authelia, and until it
# learned to wait for it (see wait_for_authelia there) the container was still
# booting when the probe fired 1-2s later. Caddy also needs a moment to notice a
# restarted upstream. Both are transient by nature, and the penalty for calling
# them permanent is losing the box's local login for a whole cycle.
#
# Worst case here is ~55s, paid only on a box where Authelia really is not
# serving. The good path costs one fast request.
PROBE_ATTEMPTS=4
PROBE_DELAY=5

# probe_local_auth — does local-auth-$DOMAIN serve a discovery document over the
# route DEX will take (the host-gateway pin, validated against the mesh CA)?
#
# `"issuer"` in the BODY is the assertion, not the status code: the failure this
# whole check exists to defeat is an HTTP 200 with an empty body.
probe_local_auth() {
    curl -sS --max-time 10 \
        --resolve "local-auth-$DOMAIN:443:127.0.0.1" \
        --cacert "$CA_CERT" \
        "https://local-auth-$DOMAIN/.well-known/openid-configuration" 2>/dev/null \
        | grep -q '"issuer"'
}

LOCAL_ACCOUNT_REACHABLE=1
if [ "$LOCAL_ACCOUNT_CLAIMED" != "1" ]; then
    : # unclaimed — the connector is not rendered anyway; skip the probe
elif ! command -v curl >/dev/null 2>&1; then
    log_warn "curl unavailable; skipping the Local Account back-channel probe"
elif [ ! -s "$CA_CERT" ]; then
    LOCAL_ACCOUNT_REACHABLE=0
    log_warn "mesh CA not present at $CA_CERT; omitting the Local Account connector this cycle"
    log_warn "  mesh-router-agent writes it (CA_CERT_PATH); the next self-check will re-probe and render."
else
    PROBE_OK=0
    ATTEMPT=1
    while [ "$ATTEMPT" -le "$PROBE_ATTEMPTS" ]; do
        if probe_local_auth; then
            PROBE_OK=1
            if [ "$ATTEMPT" -gt 1 ]; then
                log_info "local-auth-$DOMAIN answered on probe attempt $ATTEMPT/$PROBE_ATTEMPTS"
            fi
            break
        fi
        if [ "$ATTEMPT" -lt "$PROBE_ATTEMPTS" ]; then
            sleep "$PROBE_DELAY"
        fi
        ATTEMPT=$((ATTEMPT + 1))
    done

    if [ "$PROBE_OK" != "1" ]; then
        log_warn "local-auth-$DOMAIN did not return a discovery document over the on-box path after $PROBE_ATTEMPTS attempts"
        log_warn "  Check that authelia is up and that Caddy serves local-auth-$DOMAIN with the mesh CA."

        # RETENTION, and the one place this script is not fail-closed.
        #
        # Omitting a connector the box has never had costs a button that never
        # worked. Omitting one that worked yesterday REMOVES the owner's local
        # door, and if the surviving connector is a federated cloud login whose
        # account does not match, it removes every door — measured on wisera
        # 2026-09-28. So a connector a previous cycle rendered is kept.
        #
        # The original "omitting can never take Dex down" property is preserved
        # by OTHER_CONNECTOR_PRESENT: Dex tolerates one connector failing to open
        # but exits when ALL of them do, so nothing is retained on a box where
        # this is the only connector.
        if [ "$LOCAL_ACCOUNT_WAS_RENDERED" = "1" ] && [ "$OTHER_CONNECTOR_PRESENT" = "1" ]; then
            log_warn "  KEEPING it anyway: a previous cycle rendered it and another connector is present."
            log_warn "  Dex drops a connector it cannot open, so the cost is the button, not the login page."
        else
            LOCAL_ACCOUNT_REACHABLE=0
            log_warn "  Omitting the Local Account connector this cycle."
        fi
    fi
fi

if [ "$LOCAL_ACCOUNT_CLAIMED" = "1" ] && [ "$LOCAL_ACCOUNT_REACHABLE" = "1" ]; then
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
elif [ "$LOCAL_ACCOUNT_CLAIMED" != "1" ]; then
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
# THE COST IS REAL, so read this before adding one. Dex opens every oidc
# connector AT STARTUP — a live discovery fetch — and never retries one on use:
#
#   level=ERROR msg="server: Failed to open connector" id=demo
#     err="... failed to get provider: 502 Bad Gateway"
#
# Measured against the pinned digest (v2.46.0-20260806171424) on 2026-09-16:
#
#   * one connector failing is NOT fatal. The build logs "continue on connector
#     failure feature flag enabled", drops that connector and serves the rest.
#   * ALL of them failing IS fatal: "failed to open all connectors (1/1)" and
#     the process exits.
#
# So a bad drop-in normally costs only its own button — but it costs it until
# Dex is restarted, and on a box where it is the sole connector it costs every
# interactive login. The feature flag is an UNRELEASED-MASTER default; re-measure
# on the repin to a release before trusting the tolerant behaviour.
#
# Whatever writes a drop-in must therefore still confirm the issuer answers
# first — over the SAME route Dex will use, which for an on-box issuer means the
# pinned path and the mesh CA, not the public URL — and must REMOVE its file
# rather than leave a stale one behind when it cannot. See
# ensure-yundera-login.sh (public issuer) and the Local Account probe above
# (on-box issuer) — the two in-tree examples.
# A malformed drop-in exits Dex outright via a YAML parse error, with no
# per-connector tolerance.
#
# Two more rules: keep the shape above, and never reuse a connector id that is
# already taken — `authelia` (rendered above) and `yundera`
# (ensure-yundera-login.sh) — Dex rejects duplicate ids at startup.
# ---------------------------------------------------------------------------
# CONNECTORS_D and its mkdir are hoisted to the top of this script — the Local
# Account retention rule needs the glob before the render.
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
# updates propagate.
#
# The logic lives in tools/provision-dex-frontend.sh because it is NOT
# exclusive to this script: ensure-user-compose-stack-up.sh runs it too, since
# a `docker compose up` that happens before these files exist makes Docker
# create the file bind-mount sources as DIRECTORIES and permanently breaks
# `dex`. See that tool's header for the full story.
"$YND_TEMPLATE/scripts/tools/provision-dex-frontend.sh" \
    || log_warn "Dex frontend provisioning reported an error"

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
#     sudo /DATA/AppData/yundera/template/scripts/tools/authelia-user-manager.sh claim <username>
# ---------------------------------------------------------------------------
if [ "$CONNECTOR_COUNT" -eq 0 ]; then
    log_warn "Dex rendered with NO connectors — interactive login is impossible on this PCS."
    log_warn "  Cause: local account unclaimed and no drop-in connector present."
    log_warn "  Fix over SSH: sudo $YND_TEMPLATE/scripts/tools/authelia-user-manager.sh claim <username>"
fi

# Perms: dex (uid 1001) owns its tree so it can create dex.db. This now also
# covers frontend/, which lives under $DEX_ROOT — the container mounts those
# files :ro, so ownership is cosmetic there, but it must run AFTER the
# provisioning call above or the freshly copied theme stays root-owned.
chown -R "$DEX_UID:$DEX_UID" "$DEX_ROOT" 2>/dev/null || true
chmod 755 "$DEX_ROOT" 2>/dev/null || true

# Pick up the re-rendered config if Dex is already running. A mounted-file change
# does not trigger a compose recreate, so an explicit restart is needed. Silent
# on cold boot when the container does not exist yet.
if docker inspect dex >/dev/null 2>&1; then
    docker restart dex >/dev/null 2>&1 || true
fi

log_info "Dex provisioning complete (data root: $DEX_ROOT)"
