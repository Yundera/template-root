#!/bin/bash
# ensure-dex.sh - Provision the Dex OIDC broker (the PCS SSO identity provider).
#
# Responsibilities (all idempotent):
#   - render Dex config.yaml from the template every run (tracks DOMAIN changes
#     and re-emits the connector secrets),
#   - generate the Dex<->bridge connector shared secret once (BRIDGE_SECRET),
#   - read the Dex<->Authelia connector secret (AUTHELIA_DEX_SECRET, minted by
#     ensure-authelia.sh) so the Local Account connector renders,
#   - own the sqlite data dir so the dex container (uid 1001) can write dex.db,
#   - restart dex so a re-rendered config is picked up.
#
# Dex is a pure BROKER: it holds no local credential of its own. The local
# account lives in Authelia (the "Local Account" connector, see
# ensure-authelia.sh); the old enablePasswordDB break-glass admin has been
# removed. Interactive login is therefore always federated to a connector
# (Authelia or CasaOS).
#
# Storage layout (host /DATA/AppData/yundera/):
#   dex/config.yaml          rendered Dex config (re-rendered each run)
#   dex/dex.db               Dex sqlite store (clients, codes, refresh tokens, keys)
#   casaos-oidc-bridge/signing-key.json  bridge token-signing key (bridge-owned)
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
BRIDGE_ROOT="/DATA/AppData/yundera/casaos-oidc-bridge"
TEMPLATE="$YND_ROOT/dex.config.yaml.tmpl"
CONFIG_OUT="$DEX_ROOT/config.yaml"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

# ghcr.io/dexidp/dex runs as uid/gid 1001 and must own its sqlite tree.
DEX_UID=1001

mkdir -p "$DEX_ROOT" "$BRIDGE_ROOT"

DOMAIN="$("$ENV_MGR" get DOMAIN "$USER_ENV")"
if [ -z "$DOMAIN" ]; then
    log_error "DOMAIN not set in $USER_ENV; cannot render Dex config"
    exit 1
fi

# Dex<->bridge connector shared secret. Generated once and persisted in
# .pcs.secret.env (so subsequent self-checks fold it into the unified .env that
# docker compose interpolates for the bridge's CLIENT_SECRET). Also written into
# the live .env here so the SAME cycle's compose-up already sees it — this script
# runs after ensure-env-vars-valid.sh but before the compose-up steps.
BRIDGE_SECRET="$("$ENV_MGR" get BRIDGE_SECRET "$SECRET_ENV")"
if [ -z "$BRIDGE_SECRET" ]; then
    BRIDGE_SECRET="$(openssl rand -hex 32)"
    "$ENV_MGR" set BRIDGE_SECRET "$BRIDGE_SECRET" "$SECRET_ENV"
    log_info "Generated BRIDGE_SECRET (Dex<->bridge connector secret)"
fi
"$ENV_MGR" set BRIDGE_SECRET "$BRIDGE_SECRET" "$UNIFIED_ENV"

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
export DOMAIN BRIDGE_SECRET AUTHELIA_DEX_SECRET
envsubst '${DOMAIN} ${BRIDGE_SECRET} ${AUTHELIA_DEX_SECRET}' < "$TEMPLATE" > "$TMP"
mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"
log_info "Rendered Dex config at $CONFIG_OUT"

# Perms: dex (uid 1001) owns its tree so it can create dex.db.
chown -R "$DEX_UID:$DEX_UID" "$DEX_ROOT" 2>/dev/null || true
chmod 755 "$DEX_ROOT" 2>/dev/null || true
# The bridge persists its signing key here; let it write regardless of its uid.
chmod 777 "$BRIDGE_ROOT" 2>/dev/null || true

# Pick up the re-rendered config if Dex is already running. A mounted-file change
# does not trigger a compose recreate, so an explicit restart is needed. Silent
# on cold boot when the container does not exist yet.
if docker inspect dex >/dev/null 2>&1; then
    docker restart dex >/dev/null 2>&1 || true
fi

log_info "Dex provisioning complete (data root: $DEX_ROOT)"
