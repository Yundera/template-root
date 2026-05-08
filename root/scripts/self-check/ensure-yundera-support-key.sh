#!/bin/bash

# Safety net for the Yundera support SSH key.
#
# After ensure-admin-user.sh's first-run seed, the support key lives in
# admin@host's authorized_keys with nothing keeping it there — a user
# (or sshd reconfigure, or a key edit through the dashboard) can remove
# it and support access is silently gone. This script re-asserts the
# desired state every self-check tick.
#
# Opt-out: ENSURE_SUPPORT_KEY in .pcs.env. Absent / "true" / "1" =
# ensure (default). "false" / "0" = skip. Removal of the key on opt-out
# is performed by the dashboard at toggle time (api/admin/support-ensure
# POST {ensure: false}); this script never removes — it only adds.
#
# Source of truth for the public key is the orchestrator
# (${YUNDERA_USER_API}/support/ssh-key). Network failures are logged
# and we exit 0 — a one-cycle gap in the safety net is strictly better
# than blocking the rest of self-check.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"
ENV_MANAGER="$YND_ROOT/scripts/tools/env-file-manager.sh"
ADMIN_USER="admin"

ENSURE=$("$ENV_MANAGER" get ENSURE_SUPPORT_KEY "$PCS_ENV_FILE" 2>/dev/null || echo "")
case "${ENSURE,,}" in
    false|0|no|off)
        echo "ENSURE_SUPPORT_KEY=$ENSURE — opted out, skipping"
        exit 0
        ;;
esac

YUNDERA_USER_API=$("$ENV_MANAGER" get YUNDERA_USER_API "$PCS_ENV_FILE" 2>/dev/null || echo "")
if [ -z "$YUNDERA_USER_API" ]; then
    YUNDERA_USER_API="https://app.yundera.com/service/pcs/user"
fi
# URL construction mirrors SupportKey.ts in settings-center-app — keep
# them identical so the safety net and the dashboard hit the same
# endpoint and rotate together.
SUPPORT_URL="${YUNDERA_USER_API%/}/support/ssh-key"

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    echo "User '$ADMIN_USER' not found — run ensure-admin-user.sh first; skipping"
    exit 0
fi

ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
if [ -z "$ADMIN_HOME" ] || [ ! -d "$ADMIN_HOME" ]; then
    echo "Admin home dir missing; skipping"
    exit 0
fi
ADMIN_AK="$ADMIN_HOME/.ssh/authorized_keys"

# Fetch with a tight timeout — boot networking can be slow but blocking
# the rest of self-check on this is worse than missing one tick.
HTTP_RESPONSE=$(curl -sS --max-time 10 --retry 2 --retry-delay 2 \
    -w "HTTPSTATUS:%{http_code}" "$SUPPORT_URL" 2>/dev/null \
    || echo "HTTPSTATUS:000")
HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS:[0-9]*$//')

if [ "$HTTP_CODE" != "200" ]; then
    echo "Could not fetch support key from $SUPPORT_URL (HTTP $HTTP_CODE); skipping"
    exit 0
fi

# Pull publicKey + fingerprint out of the JSON without a jq dep — same
# pattern ensure-yundera-user-data.sh uses.
SUPPORT_PUBKEY=$(echo "$HTTP_BODY" | grep -o '"publicKey":"[^"]*"' | head -n1 | sed 's/"publicKey":"\(.*\)"/\1/')
SUPPORT_FP=$(echo "$HTTP_BODY" | grep -o '"fingerprint":"[^"]*"' | head -n1 | sed 's/"fingerprint":"\(.*\)"/\1/')

if [ -z "$SUPPORT_PUBKEY" ] || [ -z "$SUPPORT_FP" ]; then
    echo "Malformed response from $SUPPORT_URL; skipping"
    exit 0
fi

mkdir -p "$ADMIN_HOME/.ssh"
chmod 700 "$ADMIN_HOME/.ssh"
touch "$ADMIN_AK"
chmod 600 "$ADMIN_AK"
chown -R "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh"

# Idempotency by fingerprint — substring match would re-add on key
# rotation and create duplicates / orphans.
PRESENT=0
if [ -s "$ADMIN_AK" ]; then
    while IFS= read -r FP; do
        if [ "$FP" = "$SUPPORT_FP" ]; then
            PRESENT=1
            break
        fi
    done < <(ssh-keygen -lf "$ADMIN_AK" 2>/dev/null | awk '{print $2}')
fi

if [ "$PRESENT" = "1" ]; then
    echo "✓ Support key present in $ADMIN_AK ($SUPPORT_FP)"
    exit 0
fi

printf '%s\n' "$SUPPORT_PUBKEY" >> "$ADMIN_AK"
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_AK"
echo "→ Re-added Yundera support key to $ADMIN_AK ($SUPPORT_FP) — held in place by ENSURE_SUPPORT_KEY"
