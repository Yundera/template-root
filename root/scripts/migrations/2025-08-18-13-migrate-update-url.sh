#!/bin/bash
set -euo pipefail

# Migration: Migrate UPDATE_URL from environment to .pcs.env
# This migration moves UPDATE_URL from the environment variable to the .pcs.env file
# where it's expected by the template sync system

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

# Idempotent check
if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

# Define file paths
PCS_ENV_FILE="/DATA/AppData/casaos/apps/yundera/.pcs.env"

# Function to update or add environment variable
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local env_file="$3"
    
    # Create env file if it doesn't exist
    if [ ! -f "$env_file" ]; then
        touch "$env_file"
        echo "# PCS environment configuration" > "$env_file"
    fi
    
    if grep -q "^${var_name}=" "$env_file"; then
        # Update existing variable
        sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
        echo "Updated ${var_name} in $env_file"
    else
        # Add new variable
        echo "${var_name}=${var_value}" >> "$env_file"
        echo "Added ${var_name} to $env_file"
    fi
}

echo "=== Migrating UPDATE_URL to .pcs.env ==="

# Check if UPDATE_URL already exists in .pcs.env
if [ -f "$PCS_ENV_FILE" ] && grep -q "^UPDATE_URL=" "$PCS_ENV_FILE"; then
    EXISTING_UPDATE_URL=$(grep "^UPDATE_URL=" "$PCS_ENV_FILE" | head -1 | cut -d '=' -f2- | tr -d '"' | tr -d ' \t\r\n')
    if [ -n "$EXISTING_UPDATE_URL" ]; then
        echo "UPDATE_URL already exists in $PCS_ENV_FILE: $EXISTING_UPDATE_URL"
        echo "Migration $MIGRATION_NAME completed (already configured)"
        echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
        exit 0
    fi
fi

# Migrate UPDATE_URL from environment if it exists
if [ -n "${UPDATE_URL:-}" ]; then
    echo "Found UPDATE_URL in environment: $UPDATE_URL"
    update_env_var "UPDATE_URL" "$UPDATE_URL" "$PCS_ENV_FILE"
    chmod 644 "$PCS_ENV_FILE"  # Standard permissions for PCS config
    echo "Successfully migrated UPDATE_URL to $PCS_ENV_FILE"
else
    # Check for common default values that might need to be set
    echo "No UPDATE_URL found in environment"
    
    # Set a reasonable default if none exists
    DEFAULT_UPDATE_URL="https://github.com/Yundera/template-root/archive/refs/heads/stable.zip"
    echo "Setting default UPDATE_URL: $DEFAULT_UPDATE_URL"
    update_env_var "UPDATE_URL" "$DEFAULT_UPDATE_URL" "$PCS_ENV_FILE"
    chmod 644 "$PCS_ENV_FILE"
    echo "Set default UPDATE_URL in $PCS_ENV_FILE"
fi

# Mark completion
echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"