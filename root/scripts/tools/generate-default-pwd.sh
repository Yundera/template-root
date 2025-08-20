#!/bin/bash

# generate-default-pwd.sh - Generate DEFAULT_PWD for PCS instance
# Usage: ./generate-default-pwd.sh
# This script generates a secure random password and sets it in the .env file
# Throws error if DEFAULT_PWD already exists to prevent accidental overwrites

set -euo pipefail

SECRET_ENV_FILE="/DATA/AppData/casaos/apps/yundera/.pcs.secret.env"

# Check if secret env file exists, create it if not
if [ ! -f "$SECRET_ENV_FILE" ]; then
    touch "$SECRET_ENV_FILE"
    chmod 600 "$SECRET_ENV_FILE"  # Restrict permissions for secret file
fi

# Check if DEFAULT_PWD already exists and is not empty
if grep -q "^DEFAULT_PWD=.*[^[:space:]]" "$SECRET_ENV_FILE"; then
    echo "Warning: DEFAULT_PWD already exists. Skipping password generation."
    exit 0
fi

# Generate secure 24-character password with alphanumeric characters
# Using openssl for cryptographically secure random generation
GENERATED_PWD=$(openssl rand -base64 18 | tr -d "=+/" | cut -c1-24)

# Check if DEFAULT_PWD line exists but is empty
if grep -q "^DEFAULT_PWD=" "$SECRET_ENV_FILE"; then
    # Replace empty DEFAULT_PWD line
    sed -i "s/^DEFAULT_PWD=$/DEFAULT_PWD=$GENERATED_PWD/" "$SECRET_ENV_FILE"
else
    # Add DEFAULT_PWD line
    echo "DEFAULT_PWD=$GENERATED_PWD" >> "$SECRET_ENV_FILE"
fi