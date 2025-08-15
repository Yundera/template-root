#!/bin/bash

# ensure-yundera-user-data.sh - Fetch user data using JWT and update .env file
# This script fetches user information from yundera.com/pcs/user/info API
# and updates the .env file with the complete user data

set -euo pipefail

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source ${SCRIPT_DIR}/library/common.sh

SECRET_ENV_FILE="/DATA/AppData/casaos/apps/yundera/.pcs.secret.env"
USER_ENV_FILE="/DATA/AppData/casaos/apps/yundera/.ynd.user.env"
TEMP_SECRET_FILE="/tmp/.pcs.secret.env.update"
TEMP_USER_FILE="/tmp/.ynd.user.env.update"

log "=== Ensuring user data is up to date ==="

# Check if secret env file exists
if [ ! -f "$SECRET_ENV_FILE" ]; then
    log_error "Secret env file not found at $SECRET_ENV_FILE"
    exit 1
fi

# Create user env file if it doesn't exist
if [ ! -f "$USER_ENV_FILE" ]; then
    log "Creating new user env file at $USER_ENV_FILE"
    touch "$USER_ENV_FILE"
    chmod 644 "$USER_ENV_FILE"
fi

# Read USER_JWT from secret env file
USER_JWT=$(grep "^USER_JWT=" "$SECRET_ENV_FILE" | cut -d'=' -f2- || echo "")

if [ -z "$USER_JWT" ]; then
    log_error "USER_JWT not found in $SECRET_ENV_FILE. Cannot fetch user data."
    exit 1
fi

log "Found USER_JWT, fetching user data from yundera.com/pcs API"

# Make API call to fetch user info from yundera.com/pcs/user/info
HTTP_RESPONSE=$(curl -s -w "HTTPSTATUS:%{http_code}" \
    -H "Authorization: Bearer $USER_JWT" \
    -H "Content-Type: application/json" \
    -X POST \
    "https://yundera.com/pcs/user/info" || echo "HTTPSTATUS:000")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS:[0-9]*$//')

if [ "$HTTP_CODE" != "200" ]; then
    log_error "Failed to fetch user data. HTTP status: $HTTP_CODE, Response: $HTTP_BODY"
    exit 1
fi

log "Successfully fetched user data from API"

# Parse JSON response using basic shell tools (avoid jq dependency)
# Extract values using grep and sed
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | sed "s/\"$key\":\"\([^\"]*\)\"/\1/" || echo ""
}

# Extract user data from response
UID_VALUE=$(extract_json_value "$HTTP_BODY" "uid")
EMAIL_VALUE=$(extract_json_value "$HTTP_BODY" "email")
DOMAIN_VALUE=$(extract_json_value "$HTTP_BODY" "domain")
DOMAIN_UID=$(extract_json_value "$HTTP_BODY" "domainUid")
SIGNATURE=$(extract_json_value "$HTTP_BODY" "domainSignature")
YUNDERA_JWT=$(extract_json_value "$HTTP_BODY" "userJWT")

# Create provider string in expected format
if [ -n "$DOMAIN_VALUE" ] && [ -n "$UID_VALUE" ] && [ -n "$SIGNATURE" ]; then
    PROVIDER_STR="https://$DOMAIN_VALUE,$UID_VALUE,$SIGNATURE"
else
    log_error "Missing required user data fields for PROVIDER_STR generation"
    exit 1
fi

log "Parsed user data: UID=$UID_VALUE, DOMAIN=$DOMAIN_VALUE"

# Create updated files
cp "$SECRET_ENV_FILE" "$TEMP_SECRET_FILE"
cp "$USER_ENV_FILE" "$TEMP_USER_FILE"

# Function to update or add environment variable
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local env_file="$3"
    
    if grep -q "^${var_name}=" "$env_file"; then
        # Update existing variable
        sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        # Add new variable
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
}

# Update secret environment variables (sensitive data)
update_env_var "PROVIDER_STR" "$PROVIDER_STR" "$TEMP_SECRET_FILE"

# Update USER_JWT with yunderaJWT if available
if [ -n "$YUNDERA_JWT" ]; then
    update_env_var "USER_JWT" "$YUNDERA_JWT" "$TEMP_SECRET_FILE"
fi

# Update user environment variables (less sensitive data)
update_env_var "UID" "$UID_VALUE" "$TEMP_USER_FILE"
update_env_var "DOMAIN" "$DOMAIN_VALUE" "$TEMP_USER_FILE"

# Update email from API response (from Firebase Auth)
if [ -n "$EMAIL_VALUE" ]; then
    update_env_var "EMAIL" "$EMAIL_VALUE" "$TEMP_USER_FILE"
elif [ -n "$DOMAIN_UID" ]; then
    # Fallback to domainUid if email is not available
    update_env_var "EMAIL" "$DOMAIN_UID" "$TEMP_USER_FILE"
fi

# Extract username from domain (use part before first dot as username)
if [ -n "$DOMAIN_VALUE" ]; then
    USERNAME_VALUE=$(echo "$DOMAIN_VALUE" | cut -d'.' -f1)
    update_env_var "USERNAME" "$USERNAME_VALUE" "$TEMP_USER_FILE"
fi

# Fetch PUBLIC_IP from external service if not set or empty
CURRENT_PUBLIC_IP=$(grep "^PUBLIC_IP=" "$TEMP_USER_FILE" 2>/dev/null | cut -d'=' -f2- || echo "")
if [ -z "$CURRENT_PUBLIC_IP" ]; then
    log "Fetching public IP from external service"
    PUBLIC_IP_VALUE=$(curl -s --max-time 10 https://ifconfig.me/ip || curl -s --max-time 10 https://ipinfo.io/ip || echo "")
    if [ -n "$PUBLIC_IP_VALUE" ]; then
        update_env_var "PUBLIC_IP" "$PUBLIC_IP_VALUE" "$TEMP_USER_FILE"
        log "Updated PUBLIC_IP to $PUBLIC_IP_VALUE"
    else
        log "Could not fetch public IP, keeping empty"
        update_env_var "PUBLIC_IP" "" "$TEMP_USER_FILE"
    fi
else
    log "PUBLIC_IP already set to $CURRENT_PUBLIC_IP"
fi


# Atomically replace the original files
mv "$TEMP_SECRET_FILE" "$SECRET_ENV_FILE"
mv "$TEMP_USER_FILE" "$USER_ENV_FILE"

# Ensure proper permissions
chmod 600 "$SECRET_ENV_FILE"  # Restrictive permissions for secrets
chmod 644 "$USER_ENV_FILE"    # Standard permissions for user data

log "Successfully updated secret and user data files"
log "=== User data sync completed successfully ==="