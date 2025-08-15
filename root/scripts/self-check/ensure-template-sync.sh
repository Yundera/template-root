#!/bin/bash

# Download template from GitHub repository and sync with local root directory
# This script reads UPDATE_URL from environment files and syncs the entire template

set -e

# Check for root privileges
[ "$EUID" -eq 0 ] || { echo "Error: This script must be run as root"; exit 1; }

# Install required tools
echo "Installing required tools..."
apt-get -o DPkg::Lock::Timeout=300 update -qq && apt-get -o DPkg::Lock::Timeout=300 install -y wget unzip rsync

# Configuration
DEFAULT_TEMPLATE_URL="https://github.com/Yundera/template-root/archive/refs/heads/stable.zip"
ENV_FILE="/DATA/AppData/casaos/apps/yundera/.pcs.env"
ROOT_DIR="/DATA/AppData/casaos/apps/yundera"
TEMP_DIR=$(mktemp -d)
BACKUP_DIR="/tmp/root-backup-$(date +%s)"

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Starting template sync..."

# Get template URL from .env or use default
UPDATE_URL=$(grep "^UPDATE_URL=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"' | tr -d ' \t\r\n')
[ -z "$UPDATE_URL" ] && UPDATE_URL="$DEFAULT_TEMPLATE_URL"

echo "Using update URL: $UPDATE_URL"

# Handle local development mode
if [ "$UPDATE_URL" = "local" ]; then
    echo "Local development mode detected (UPDATE_URL=local)"
    echo "Skipping template sync - using local development files"
    echo "Template sync completed successfully (local mode)"
    exit 0
fi

# Validate URL
[[ "$UPDATE_URL" == *.zip ]] || { echo "Error: UPDATE_URL must end with .zip"; exit 1; }

# Download and extract template
echo "Downloading and extracting template..."
wget --secure-protocol=auto --timeout=30 --tries=3 -O "$TEMP_DIR/template.zip" "$UPDATE_URL" || {
    echo "Error: Failed to download template"
    exit 1
}

unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR" || {
    echo "Error: Failed to extract template"
    exit 1
}

# Find template root directory
TEMPLATE_ROOT=$(find "$TEMP_DIR" -name "root" -type d | head -n 1)
[ -d "$TEMPLATE_ROOT" ] || { echo "Error: Template does not contain 'root' directory"; exit 1; }

# Create backup if root directory exists
[ -d "$ROOT_DIR" ] && cp -r "$ROOT_DIR" "$BACKUP_DIR"

# Build rsync command with proper exclusions
RSYNC_OPTS=("-av" "--delete")

# error if "$TEMPLATE_ROOT/.ignore" don't exsist
if [ ! -f "$TEMPLATE_ROOT/.ignore" ]; then
    echo "Error: Template .ignore file not found at $TEMPLATE_ROOT/.ignore"
    exit 1
fi

# Debug: Show what will be excluded
echo "Files/patterns to be excluded:"
cat "$TEMPLATE_ROOT/.ignore"

# Add exclude-from option
RSYNC_OPTS+=("--exclude-from=$TEMPLATE_ROOT/.ignore")

# Sync template to root directory (no eval needed)
echo "Syncing template files to root directory..."
mkdir -p "$ROOT_DIR"

# Force filesystem sync and wait for stability
sync
sleep 2
sync

if rsync "${RSYNC_OPTS[@]}" "$TEMPLATE_ROOT/" "$ROOT_DIR/"; then
    # Force filesystem sync and wait for stability
    sync
    sleep 2
    sync
    rm -rf "$BACKUP_DIR"
else
    echo "Error: Template sync failed, restoring backup"
    [ -d "$BACKUP_DIR" ] && { rm -rf "$ROOT_DIR"; mv "$BACKUP_DIR" "$ROOT_DIR"; }
    exit 1
fi

# Set proper ownership and permissions
chown -R pcs:pcs "$ROOT_DIR"
find "$ROOT_DIR/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "Template sync completed successfully"