#!/bin/bash
# feature-support-key.sh - Turn the Yundera support SSH key on or off.
#
#   status | enable | disable
#
# The key lets Yundera SSH in to help when something inside the PCS breaks.
# ensure-support-key.sh re-asserts it on every self-check tick;
# ENSURE_SUPPORT_KEY in .pcs.env is the opt-out it already honours.
#
# DISABLE DOES TWO THINGS, and that is the reason this script exists rather than
# a bare `env-file-manager.sh set`. ensure-support-key.sh only ever ADDS — it has
# no removal path, so a failed fetch can never lock support out. Writing the flag
# therefore stops the key coming back but leaves the one on disk in place. Off
# has to mean gone, so this removes it too.
#
# Prints {"id","enabled"} on stdout; errors on stderr with a non-zero exit.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
ENSURE="$YND_ROOT/scripts/self-check/ensure-support-key.sh"
ADMIN_USER="admin"
FLAG="ENSURE_SUPPORT_KEY"

error() { echo "ERROR: $1" >&2; exit 1; }

env_get() { "$ENV_MGR" get "$1" "$PCS_ENV" 2>/dev/null || echo ""; }

# Polarity matches ensure-support-key.sh:48 — absent/true/1/yes/on = on,
# false/0/no/off = off, anything else on. Keep the two in agreement.
enabled() {
    case "$(env_get "$FLAG" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        false|0|no|off) echo false ;;
        *)              echo true ;;
    esac
}

emit() { printf '{"id":"support-key","enabled":%s}\n' "$1"; }

# Remove by FINGERPRINT, not substring: the key rotates, and a text match would
# leave the old one behind. Fingerprint each line separately — `ssh-keygen -lf`
# over the whole file skips blanks and comments, so its Nth output line is not
# the Nth file line.
remove_key() {
    local api url pubkey fp home ak tmp line lfp

    api="$(env_get OPERATOR_API)"
    [ -n "$api" ] || api="$(env_get YUNDERA_API)"
    [ -n "$api" ] || api="https://app.yundera.com/service/pcs"
    url="${api%/}/support/ssh-key"

    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)" || error "user '$ADMIN_USER' not found"
    ak="$home/.ssh/authorized_keys"
    [ -s "$ak" ] || return 0

    pubkey="$(curl -sS --max-time 10 "$url" 2>/dev/null | grep -o '"publicKey":"[^"]*"' | head -n1 | sed 's/"publicKey":"\(.*\)"/\1/')" \
        || error "could not reach $url; the flag is set but the key is still authorized"
    [ -n "$pubkey" ] || error "no key in the response from $url; the flag is set but the key is still authorized"
    fp="$(printf '%s\n' "$pubkey" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
    [ -n "$fp" ] || error "could not fingerprint the support key"

    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        lfp="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
        [ "$lfp" = "$fp" ] && continue
        printf '%s\n' "$line" >> "$tmp"
    done < "$ak"

    # Write INTO the file, don't `mv` over it: mktemp gives 0600 root, and sshd
    # refuses an authorized_keys with the wrong ownership.
    cat "$tmp" > "$ak"
    rm -f "$tmp"
    chmod 600 "$ak"
    chown "$ADMIN_USER:$ADMIN_USER" "$ak" 2>/dev/null || true
}

case "${1:-}" in
    status)
        emit "$(enabled)"
        ;;
    enable)
        "$ENV_MGR" set "$FLAG" true "$PCS_ENV" >/dev/null
        "$ENSURE" >/dev/null || error "flag set, but ensure-support-key.sh failed"
        emit true
        ;;
    disable)
        "$ENV_MGR" set "$FLAG" false "$PCS_ENV" >/dev/null
        remove_key
        emit false
        ;;
    *)
        echo "Usage: $(basename "$0") status|enable|disable" >&2
        exit 1
        ;;
esac
