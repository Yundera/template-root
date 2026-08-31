#!/bin/bash
# feature-yundera-login.sh - Turn the "Yundera Login" Dex connector on or off.
#
#   status | enable | disable
#
# Lets the owner sign in with their Yundera cloud account instead of (or as well
# as) the PCS-local credential Authelia holds.
#
# ensure-yundera-login.sh does all the work — client registration, the issuer
# probe, writing or removing dex/connectors.d/yundera.yaml, re-rendering Dex — and
# already honours YUNDERA_LOGIN_ENABLED in .pcs.env. This script writes the flag
# and re-runs it so the login page changes now rather than at the next tick.
#
# NOTE FOR CALLERS: on a PCS with no local account yet, Dex offers no Local
# Account connector, so this is the only interactive login. Disabling it there
# leaves only the support SSH key. This script does not stop you — a UI that
# exposes it should (`onboarding.sh status` reports `claimed`).
#
# Prints {"id","enabled"} on stdout; errors on stderr with a non-zero exit.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
ENSURE="$YND_ROOT/scripts/self-check/ensure-yundera-login.sh"
FLAG="YUNDERA_LOGIN_ENABLED"

error() { echo "ERROR: $1" >&2; exit 1; }

env_get() { "$ENV_MGR" get "$1" "$PCS_ENV" 2>/dev/null || echo ""; }

# Polarity matches ensure-yundera-login.sh:86 — absent/true/1/yes/on = on,
# false/0/no/off = off, anything else on. Keep the two in agreement.
enabled() {
    case "$(env_get "$FLAG" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        false|0|no|off) echo false ;;
        *)              echo true ;;
    esac
}

emit() { printf '{"id":"yundera-login","enabled":%s}\n' "$1"; }

case "${1:-}" in
    status)
        emit "$(enabled)"
        ;;
    enable)
        "$ENV_MGR" set "$FLAG" true "$PCS_ENV" >/dev/null
        "$ENSURE" >/dev/null || error "flag set, but ensure-yundera-login.sh failed"
        emit true
        ;;
    disable)
        "$ENV_MGR" set "$FLAG" false "$PCS_ENV" >/dev/null
        "$ENSURE" >/dev/null || error "flag set, but ensure-yundera-login.sh failed"
        emit false
        ;;
    *)
        echo "Usage: $(basename "$0") status|enable|disable" >&2
        exit 1
        ;;
esac
