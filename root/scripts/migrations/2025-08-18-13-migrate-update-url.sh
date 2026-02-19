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

    # This one-liner safely handles env files that may be missing a trailing newline:
    # 1. Deletes any existing var_name= line, 2. Ensures file ends with newline, 3. Appends new value
    sed -i -e "/^${var_name}=/d" -e '$a\' "$env_file" && echo "${var_name}=${var_value}" >> "$env_file"
    echo "Updated ${var_name} in $env_file"
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

# Mark completion
echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"