#!/bin/bash
# ensure-yundera-login.sh - Provision the "Yundera Login" Dex connector.
#
# Lets the PCS owner sign in with their Yundera (cloud) account. The IdP is the
# orchestrator's OIDC service (issuer ${OPERATOR_API}/auth); unlike the Authelia
# connector, whose secret is local, this connector's client is registered
# DYNAMICALLY: POST the PCS's USER_JWT to ${OPERATOR_API}/auth/pcs-client, which
# returns a client_id/secret scoped to this PCS's own auth-${DOMAIN} callback
# (idempotent — stable across runs).
#
# This script owns the whole Yundera-Login perimeter and nothing else. It writes
# a single drop-in, dex/connectors.d/yundera.yaml, which ensure-dex.sh
# concatenates into the rendered Dex config. Dex knows nothing about Yundera and
# neither does ensure-dex.sh — that script is a pure renderer/glue step now.
#
# Enable/disable with YUNDERA_LOGIN_ENABLED in .pcs.env (default: enabled).
# Set it to 0/false/no on a PCS where the connector makes no sense — the demo
# box is the case that motivated the knob: its owner is the demo service's own
# account, so the orchestrator IdP's owner policy denies every visitor AFTER
# they have typed real credentials into a real login page. A dead end that asks
# for a password is worse than no button.
#
# ORDER: must run BEFORE ensure-dex.sh (which is what actually renders and
# restarts Dex). It is nonetheless order-independent — when the drop-in's
# content changes it re-runs ensure-dex.sh itself, so a manual invocation or the
# one tick where a newly-added script sorts last still converges immediately.
#
# FAIL-OPEN, ALWAYS. The drop-in is CACHE, never config: on any doubt — disabled,
# no USER_JWT, IdP unreachable, registration refused, discovery not answering —
# the file is REMOVED rather than left at its last-good value, and this script
# still exits 0. Two reasons:
#   - login must never hard-depend on the Yundera cloud; Authelia has to keep
#     working when yundera.com has a bad night;
#   - Dex resolves EVERY oidc connector's discovery document at startup and
#     treats failure as FATAL ("failed to get provider: 502" → process exits).
#     A stale drop-in pointing at a down issuer therefore takes ALL interactive
#     login on this PCS down with it, Local Account included. Hence the probe
#     below: never write a connector whose issuer has not just answered.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

DEX_ROOT="/DATA/AppData/yundera/dex"
CONNECTORS_D="$DEX_ROOT/connectors.d"
DROPIN="$CONNECTORS_D/yundera.yaml"
ENSURE_DEX="$YND_ROOT/scripts/self-check/ensure-dex.sh"

PCS_ENV="$YND_ROOT/.pcs.env"
SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

# ghcr.io/dexidp/dex runs as uid/gid 1001 and owns its whole tree (ensure-dex.sh
# chowns it recursively); match that here so the drop-in does not flip ownership
# back and forth between runs.
DEX_UID=1001

mkdir -p "$CONNECTORS_D"

# Re-render Dex only when this script actually changed the drop-in. Costs a Dex
# restart, so it must not fire on every tick.
# Tolerant on purpose: ensure-dex.sh runs on its own later in the cycle and
# reports its own failures, and this script must not turn "Dex is unhappy for an
# unrelated reason" into a failure of the Yundera-Login step.
rerender_dex() {
    [ -f "$ENSURE_DEX" ] || return 0
    bash "$ENSURE_DEX" || log_warn "ensure-dex.sh failed while re-rendering for the Yundera Login connector"
}

# Remove the drop-in (the fail-open path). Quiet when there was nothing to
# remove — that is the steady state on a PCS where the connector is disabled.
drop_connector() {
    local reason="$1"
    if [ -f "$DROPIN" ]; then
        rm -f "$DROPIN"
        log_warn "Removed the Yundera Login connector: $reason"
        rerender_dex
    else
        log_info "Yundera Login connector not configured: $reason"
    fi
}

# --- is it wanted here? ------------------------------------------------------
ENABLED="$("$ENV_MGR" get YUNDERA_LOGIN_ENABLED "$PCS_ENV")"
case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
        drop_connector "disabled by YUNDERA_LOGIN_ENABLED in .pcs.env"
        exit 0
        ;;
esac

# --- inputs ------------------------------------------------------------------
# Every one of these is a legitimate transient state on a half-provisioned host,
# so none of them is an error: no inputs, no connector, exit 0.
DOMAIN="$("$ENV_MGR" get DOMAIN "$USER_ENV")"
OPERATOR_API="$("$ENV_MGR" get OPERATOR_API "$PCS_ENV")"
# Pre-rename name — see migrations/2026-08-04-11-rename-yundera-api.sh.
[ -n "$OPERATOR_API" ] || OPERATOR_API="$("$ENV_MGR" get YUNDERA_API "$PCS_ENV")"
USER_JWT="$("$ENV_MGR" get USER_JWT "$SECRET_ENV")"

if [ -z "$DOMAIN" ]; then
    drop_connector "DOMAIN unset in $USER_ENV"
    exit 0
fi
if [ -z "$OPERATOR_API" ] || [ -z "$USER_JWT" ]; then
    drop_connector "OPERATOR_API or USER_JWT unset"
    exit 0
fi

ISSUER="${OPERATOR_API}/auth"
REDIRECT_URI="https://auth-${DOMAIN}/callback"

# --- register this PCS's client ----------------------------------------------
# Idempotent server-side: the same PCS gets the same client back, so this runs
# on every tick without accumulating clients.
REG="$(curl -fsS --max-time 20 \
    -H "Authorization: Bearer $USER_JWT" \
    -H "Content-Type: application/json" \
    -X POST "${OPERATOR_API}/auth/pcs-client" \
    -d "{\"redirect_uris\":[\"${REDIRECT_URI}\"]}" 2>/dev/null || true)"

CLIENT_ID="$(printf '%s' "$REG" | grep -o '"client_id":"[^"]*"' | sed 's/.*:"\([^"]*\)"/\1/' || true)"
CLIENT_SECRET="$(printf '%s' "$REG" | grep -o '"client_secret":"[^"]*"' | sed 's/.*:"\([^"]*\)"/\1/' || true)"

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    drop_connector "client registration at ${OPERATOR_API}/auth/pcs-client returned no client_id/secret"
    exit 0
fi

# --- confirm the issuer answers ----------------------------------------------
# Exactly the request Dex makes at startup, over exactly the URL Dex uses. If it
# does not answer now it will not answer for Dex either, and writing the
# connector would stop Dex from starting at all.
if ! curl -fsS --max-time 10 "${ISSUER}/.well-known/openid-configuration" >/dev/null 2>&1; then
    drop_connector "issuer ${ISSUER} did not serve its discovery document"
    exit 0
fi

# --- render the drop-in ------------------------------------------------------
# Two-space indent: the file is concatenated verbatim under the template's
# `connectors:` key. Values are written fully expanded (ensure-dex.sh only
# envsubsts ${DOMAIN} in drop-ins, and this script re-renders every tick anyway,
# so a domain change self-heals on the next run).
#
# The id `yundera` used to be rendered by ensure-dex.sh itself and is still
# reserved: Dex refuses to start on a duplicate connector id.
TMP="$(mktemp)"
chmod 600 "$TMP"
cat > "$TMP" <<YAML
  # Yundera Login — the operator's cloud account, federated from the
  # orchestrator's OIDC IdP. Written by ensure-yundera-login.sh; do not edit.
  - type: oidc
    id: yundera
    name: Yundera Login
    config:
      issuer: ${ISSUER}
      clientID: ${CLIENT_ID}
      clientSecret: "${CLIENT_SECRET}"
      redirectURI: ${REDIRECT_URI}
      userNameKey: email
      getUserInfo: true
      # The IdP reports email_verified honestly (the real Firebase value) and
      # Yundera accounts are not guaranteed verified at signup. Without this Dex
      # rejects any account whose Firebase email is unverified — locking real
      # owners out of their own PCS. Owner enforcement happens upstream in the
      # IdP (oidcAPI.ts ownerPolicy), so email verification is not the
      # access-control boundary here.
      insecureSkipEmailVerified: true
      # Forward the IdP's group membership. Without this Dex silently drops the
      # claim and the admin dashboard sees no groups at all — which means the
      # PCS owner is treated as a plain user and loses the dashboard
      # (settings-center-app derives its admin role from \`admins\`).
      #
      # NOTE the asymmetry with the Authelia connector, which also lists
      # 'groups' in its scopes: this IdP exposes groups through the PROFILE
      # scope (oidcAPI.ts -> claims: { profile: ["groups"] }) and defines no
      # 'groups' scope at all. Requesting one here would ask for a scope the
      # provider does not have. \`profile\` below is what carries it.
      #
      # "insecure" refers to staleness, not exposure: Dex only refreshes group
      # claims when the ID token is refreshed, so an ownership change does not
      # take effect until the user logs in again.
      insecureEnableGroups: true
      scopes:
        - openid
        - profile
        - email
YAML

if [ -f "$DROPIN" ] && cmp -s "$TMP" "$DROPIN"; then
    rm -f "$TMP"
    log_info "Yundera Login connector up to date (client ${CLIENT_ID})"
    exit 0
fi

mv "$TMP" "$DROPIN"
chmod 600 "$DROPIN"
chown "$DEX_UID:$DEX_UID" "$DROPIN" 2>/dev/null || true
log_info "Wrote the Yundera Login connector (client ${CLIENT_ID})"
rerender_dex
