#!/bin/bash

# ensure-yundera-user-data.sh - Fetch user data using JWT and update .env file
# This script fetches user information from the configured Yundera API endpoint
# and updates the .env file with the complete user data
#
# API Configuration:
# - Reads YUNDERA_USER_API from .pcs.env file
# - If not configured, uses default: https://app.yundera.com/service/pcs/user
# - Makes GET request to fetch user data using configured or default endpoint

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
SECRET_ENV_FILE="$YND_ROOT/.pcs.secret.env"
USER_ENV_FILE="$YND_ROOT/.ynd.user.env"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"

# Read Yundera user API URL from PCS env file or use default
YUNDERA_USER_API=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get YUNDERA_USER_API "$PCS_ENV_FILE")

# Use default URL if YUNDERA_USER_API is not configured or empty
if [ -z "$YUNDERA_USER_API" ]; then
    YUNDERA_USER_API="https://app.yundera.com/service/pcs/user"
    echo "Using default YUNDERA_USER_API: $YUNDERA_USER_API"
else
    echo "Using configured YUNDERA_USER_API: $YUNDERA_USER_API"
fi

# Create user env file if it doesn't exist
if [ ! -f "$USER_ENV_FILE" ]; then
    echo "Creating new user env file at $USER_ENV_FILE"
    touch "$USER_ENV_FILE"
    chmod 644 "$USER_ENV_FILE"
fi

# Check if secret env file exists
if [ ! -f "$SECRET_ENV_FILE" ]; then
    echo "ERROR: Secret env file not found at $SECRET_ENV_FILE"
    exit 1
fi

# Read USER_JWT from secret env file
USER_JWT=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get USER_JWT "$SECRET_ENV_FILE")

if [ -z "$USER_JWT" ]; then
    echo "ERROR: USER_JWT not found in $SECRET_ENV_FILE. Cannot fetch user data."
    exit 1
fi

echo "Found USER_JWT (${#USER_JWT} chars), fetching user data from ${YUNDERA_USER_API}/info"

# Make API call to fetch user info from configured API endpoint
HTTP_RESPONSE=$(curl -s -w "HTTPSTATUS:%{http_code}" \
    -H "Authorization: Bearer $USER_JWT" \
    -H "Content-Type: application/json" \
    -X GET \
    "${YUNDERA_USER_API}/info" || echo "HTTPSTATUS:000")

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
$YND_ROOT/scripts/tools/env-file-manager.sh set PROVIDER_STR "$RECV_PROVIDER_STR" "$SECRET_ENV_FILE"
$YND_ROOT/scripts/tools/env-file-manager.sh set USER_JWT "$RECV_USER_JWT" "$SECRET_ENV_FILE"

# Update user environment variables (less sensitive data)
$YND_ROOT/scripts/tools/env-file-manager.sh set UID "$RECV_UID" "$USER_ENV_FILE"
$YND_ROOT/scripts/tools/env-file-manager.sh set DOMAIN "$RECV_DOMAIN" "$USER_ENV_FILE"

# Update email from API response (from Firebase Auth)
$YND_ROOT/scripts/tools/env-file-manager.sh set EMAIL "$RECV_EMAIL" "$USER_ENV_FILE"

# Ensure proper permissions
chmod 600 "$SECRET_ENV_FILE"  # Restrictive permissions for secrets
chmod 644 "$USER_ENV_FILE"    # Standard permissions for user data

echo "Successfully updated secret and user data files (UID=$RECV_UID, DOMAIN=$RECV_DOMAIN)"