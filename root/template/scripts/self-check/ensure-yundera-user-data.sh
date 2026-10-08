#!/bin/bash

# ensure-yundera-user-data.sh - Make sure the box holds its identity
# (USER_JWT, PROVIDER_STR, UID, DOMAIN, EMAIL).
#
# Push first (pcs-orchestrator doc/identity-push.md): a pushed RS256 USER_JWT
# with more than 2 days left means the operator is keeping this box current, and
# there is nothing to do. Otherwise ring the operator's doorbell — no credential
# needed, it pushes to whichever PCS owns this IP — and wait for the push to
# land through the admin app. A box that lost every env file recovers this way.
#
# Pull second, while the operator still serves it: fetch user information with
# the stored USER_JWT and update the env files, as before.
#
# API Configuration:
# - Reads OPERATOR_API from .pcs.env file (bare orchestrator base, no /user)
# - If not configured, uses default: https://app.yundera.com/service/pcs
# - Makes GET request to ${OPERATOR_API}/user/info to fetch user data

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
SECRET_ENV_FILE="$YND_ROOT/.pcs.secret.env"
USER_ENV_FILE="$YND_ROOT/.ynd.user.env"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"

# Read Yundera API base from PCS env file or use default
OPERATOR_API=$("$YND_TEMPLATE/scripts/tools/env-file-manager.sh" get OPERATOR_API "$PCS_ENV_FILE")

if [ -z "$OPERATOR_API" ]; then
    OPERATOR_API="https://app.yundera.com/service/pcs"
    echo "Using default OPERATOR_API: $OPERATOR_API"
else
    echo "Using configured OPERATOR_API: $OPERATOR_API"
fi

# Create user env file if it doesn't exist
if [ ! -f "$USER_ENV_FILE" ]; then
    echo "Creating new user env file at $USER_ENV_FILE"
    touch "$USER_ENV_FILE"
    chmod 644 "$USER_ENV_FILE"
fi

# A wiped box may have lost it; the push recreates the contents.
if [ ! -f "$SECRET_ENV_FILE" ]; then
    install -m 600 /dev/null "$SECRET_ENV_FILE"
fi

source "$YND_TEMPLATE/scripts/library/identity.sh"

ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"

# True when the box holds a fresh pushed token and the identity it came with.
identity_complete() {
    identity_token_fresh "$("$ENV_MGR" get USER_JWT "$SECRET_ENV_FILE")" \
        && [ -n "$("$ENV_MGR" get PROVIDER_STR "$SECRET_ENV_FILE")" ] \
        && [ -n "$("$ENV_MGR" get UID "$USER_ENV_FILE")" ] \
        && [ -n "$("$ENV_MGR" get DOMAIN "$USER_ENV_FILE")" ]
}

if identity_complete; then
    echo "Identity delivered by push, token valid until $(date -u -d "@$(jwt_exp "$("$ENV_MGR" get USER_JWT "$SECRET_ENV_FILE")")" '+%Y-%m-%d %H:%M UTC')"
    exit 0
fi

# The operator answers the doorbell asynchronously, through the admin app; a
# push takes seconds. It rate-limits rings per IP, so a ring at boot followed
# by this one is fine: this loop sees the push the first ring caused.
if identity_ring_doorbell "$OPERATOR_API"; then
    for _ in $(seq 1 15); do
        sleep 3
        if identity_complete; then
            echo "Identity delivered by push"
            exit 0
        fi
    done
    echo "Doorbell rang, no push arrived within 45s; falling back to pull"
else
    echo "Doorbell at ${OPERATOR_API}/identity/doorbell did not answer 204 (operator without identity push, or unreachable); falling back to pull"
fi

# Read USER_JWT from secret env file
USER_JWT=$("$ENV_MGR" get USER_JWT "$SECRET_ENV_FILE")

if [ -z "$USER_JWT" ]; then
    echo "ERROR: USER_JWT not found in $SECRET_ENV_FILE and no identity was pushed. The operator pushes on its next refresh, or run \`pcs identity push\` for this PCS."
    exit 1
fi

echo "Found USER_JWT (${#USER_JWT} chars), fetching user data from ${OPERATOR_API}/user/info"

# Make API call to fetch user info from configured API endpoint
HTTP_RESPONSE=$(curl -s -w "HTTPSTATUS:%{http_code}" \
    -H "Authorization: Bearer $USER_JWT" \
    -H "Content-Type: application/json" \
    -X GET \
    "${OPERATOR_API}/user/info" || echo "HTTPSTATUS:000")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS:[0-9]*$//')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: Failed to fetch user data. HTTP status: $HTTP_CODE, Response: $HTTP_BODY"
    exit 1
fi

# Parse JSON response using basic shell tools (avoid jq dependency)
# Extract values using grep and sed
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | sed "s/\"$key\":\"\([^\"]*\)\"/\1/" || echo ""
}

# Extract user data from response
RECV_UID=$(extract_json_value "$HTTP_BODY" "uid")
RECV_EMAIL=$(extract_json_value "$HTTP_BODY" "email")
RECV_DOMAIN=$(extract_json_value "$HTTP_BODY" "domain")
RECV_PROVIDER_STR=$(extract_json_value "$HTTP_BODY" "domainSignature")
RECV_USER_JWT=$(extract_json_value "$HTTP_BODY" "userJWT")

# Update secret environment variables (sensitive data)
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set PROVIDER_STR "$RECV_PROVIDER_STR" "$SECRET_ENV_FILE"
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set USER_JWT "$RECV_USER_JWT" "$SECRET_ENV_FILE"

# Update user environment variables (less sensitive data)
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set UID "$RECV_UID" "$USER_ENV_FILE"
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set DOMAIN "$RECV_DOMAIN" "$USER_ENV_FILE"

# Update email from API response (from Firebase Auth)
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set EMAIL "$RECV_EMAIL" "$USER_ENV_FILE"

# Ensure proper permissions
chmod 600 "$SECRET_ENV_FILE"  # Restrictive permissions for secrets
chmod 644 "$USER_ENV_FILE"    # Standard permissions for user data

echo "Successfully updated secret and user data files (UID=$RECV_UID, DOMAIN=$RECV_DOMAIN)"