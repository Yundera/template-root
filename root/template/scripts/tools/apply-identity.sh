#!/bin/bash
# apply-identity.sh - write a pushed identity into the env files.
#
# Called by the admin app's /api/identity/push (settings-center-app,
# backend/identity/applyIdentity.ts) AFTER it has decrypted the bundle and
# verified its signature, host and freshness. This script only writes.
#
# Input: KEY=VALUE lines on stdin, never on the command line, so the secrets do
# not show in `ps`. Keys: UID DOMAIN EMAIL DOMAIN_UID USER_JWT PROVIDER_STR.
# Same files and keys as ensure-yundera-user-data.sh's pull.
#
# Prints "identity-changed" when PROVIDER_STR or DOMAIN changed: the mesh only
# picks those up through ensure-mesh-installed.sh, so the caller starts a
# self-check.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_MGR="$SCRIPT_DIR/env-file-manager.sh"
SECRET_ENV_FILE="$YND_ROOT/.pcs.secret.env"
USER_ENV_FILE="$YND_ROOT/.ynd.user.env"

declare -A V=()
while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    case "$key" in
        UID|DOMAIN|EMAIL|DOMAIN_UID|USER_JWT|PROVIDER_STR) V[$key]="${line#*=}" ;;
    esac
done

for key in UID DOMAIN USER_JWT PROVIDER_STR; do
    if [ -z "${V[$key]:-}" ]; then
        echo "ERROR: $key missing from the pushed identity" >&2
        exit 2
    fi
done

# A wiped box may have neither file.
[ -f "$SECRET_ENV_FILE" ] || install -m 600 /dev/null "$SECRET_ENV_FILE"
[ -f "$USER_ENV_FILE" ] || install -m 644 /dev/null "$USER_ENV_FILE"

OLD_PROVIDER_STR=$("$ENV_MGR" get PROVIDER_STR "$SECRET_ENV_FILE")
OLD_DOMAIN=$("$ENV_MGR" get DOMAIN "$USER_ENV_FILE")

"$ENV_MGR" set PROVIDER_STR "${V[PROVIDER_STR]}" "$SECRET_ENV_FILE"
"$ENV_MGR" set USER_JWT "${V[USER_JWT]}" "$SECRET_ENV_FILE"
"$ENV_MGR" set UID "${V[UID]}" "$USER_ENV_FILE"
"$ENV_MGR" set DOMAIN "${V[DOMAIN]}" "$USER_ENV_FILE"
"$ENV_MGR" set EMAIL "${V[EMAIL]:-}" "$USER_ENV_FILE"

chmod 600 "$SECRET_ENV_FILE"
chmod 644 "$USER_ENV_FILE"

echo "Applied pushed identity (UID=${V[UID]}, DOMAIN=${V[DOMAIN]})"
if [ "$OLD_PROVIDER_STR" != "${V[PROVIDER_STR]}" ] || [ "$OLD_DOMAIN" != "${V[DOMAIN]}" ]; then
    echo "identity-changed"
fi
