#!/bin/bash

# Download template from GitHub repository and sync with local root directory
# This script reads UPDATE_URL from environment files and syncs the entire template

set -e

# Check for root privileges
[ "$EUID" -eq 0 ] || { echo "✗ This script must be run as root"; exit 1; }

# Install required tools
echo "→ Installing required tools..."
if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y wget curl apt-utils unzip rsync; } >/dev/null 2>&1; then
    echo "✗ Failed to install required tools. Running with verbose output for debugging:"
    apt-get update && apt-get install -y wget unzip rsync
    exit 1
fi

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

# Function to run migrations from a template directory
run_migrations() {
    local template_root="$1"
    local migrations_dir="$template_root/scripts/migrations"
    local migration_runner="$template_root/scripts/tools/run-migrations.sh"
    
    # Make all migration-related scripts executable first
    echo "→ Setting executable permissions on migration scripts..."
    if [ -d "$migrations_dir" ]; then
        find "$migrations_dir" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    fi
    if [ -f "$migration_runner" ]; then
        chmod +x "$migration_runner" 2>/dev/null || true
    fi
    
    # Debug: Show what we found
    echo "→ Checking migration setup..."
    echo "  migrations_dir ($migrations_dir): $([ -d "$migrations_dir" ] && echo "exists" || echo "missing")"
    echo "  migration_runner ($migration_runner): $([ -x "$migration_runner" ] && echo "executable" || echo "not executable/missing")"
    
    if [ -d "$migrations_dir" ]; then
        migration_scripts_count=$(find "$migrations_dir" -name "*.sh" -type f | wc -l)
        echo "  Found $migration_scripts_count migration scripts in directory"
    fi
    
    if [ -d "$migrations_dir" ] && [ -x "$migration_runner" ]; then
        migration_log=$(mktemp)
        "$migration_runner" "$migrations_dir" >"$migration_log" 2>&1
        migration_exit_code=$?
        
        # Always show migration output regardless of success/failure
        cat "$migration_log" || echo "(no migration log output)"
        rm -f "$migration_log"
        
        if [ $migration_exit_code -ne 0 ]; then
            echo "✗ Migration runner failed (exit $migration_exit_code)"
            return 1
        fi
        
        echo "✓ Migrations completed successfully"
    else
        echo "→ Skipping migrations (conditions not met after setup)"
    fi
    return 0
}

# Get template URL from .env or use default
UPDATE_URL=$(grep "^UPDATE_URL=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"' | tr -d ' \t\r\n')
[ -z "$UPDATE_URL" ] && UPDATE_URL="$DEFAULT_TEMPLATE_URL"

echo "→ Using update URL: $UPDATE_URL"

# Handle local development mode
if [ "$UPDATE_URL" = "local" ]; then
    echo "→ Local mode: running migrations..."
    
    # Run migrations from local template
    if ! run_migrations "$ROOT_DIR"; then
        exit 1
    fi
    
    echo "✓ Template sync completed successfully (local mode)"
    exit 0
fi

# Validate URL
[[ "$UPDATE_URL" == *.zip ]] || { echo "✗ UPDATE_URL must end with .zip"; exit 1; }

# Download and extract template
echo "→ Downloading template..."
if ! wget --secure-protocol=auto --timeout=30 --tries=3 -q -O "$TEMP_DIR/template.zip" "$UPDATE_URL"; then
    echo "✗ Failed to download template from: $UPDATE_URL"
    echo "Debug info: wget output:"
    wget --secure-protocol=auto --timeout=30 --tries=3 -O "$TEMP_DIR/template.zip" "$UPDATE_URL" || true
    exit 1
fi

if ! unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR"; then
    echo "✗ Failed to extract template archive"
    echo "Debug info: File size: $(ls -lh "$TEMP_DIR/template.zip" 2>/dev/null | awk '{print $5}' || echo 'unknown')"
    echo "Debug info: File type: $(file "$TEMP_DIR/template.zip" 2>/dev/null || echo 'unknown')"
    exit 1
fi

# Find template root directory
TEMPLATE_ROOT=$(find "$TEMP_DIR" -name "root" -type d | head -n 1)
if [ ! -d "$TEMPLATE_ROOT" ]; then
    echo "✗ Template does not contain 'root' directory"
    echo "Debug info: Template contents:"
    find "$TEMP_DIR" -type d | head -10
    exit 1
fi

# Run migrations from the new template before syncing
if ! run_migrations "$TEMPLATE_ROOT"; then
    echo "✗ Template sync aborted due to migration failure."
    exit 1
fi

# Create backup if root directory exists
[ -d "$ROOT_DIR" ] && cp -r "$ROOT_DIR" "$BACKUP_DIR"

# Build rsync command with proper exclusions
RSYNC_OPTS=("-a" "--delete")

# error if "$TEMPLATE_ROOT/.ignore" don't exsist
if [ ! -f "$TEMPLATE_ROOT/.ignore" ]; then
    echo "✗ Template .ignore file not found at $TEMPLATE_ROOT/.ignore"
    exit 1
fi

# Files/patterns will be excluded based on .ignore file (shown only on rsync error)

# Add exclude-from option
RSYNC_OPTS+=("--exclude-from=$TEMPLATE_ROOT/.ignore")

# Sync template to root directory
echo "→ Syncing files..."
mkdir -p "$ROOT_DIR"

# Force filesystem sync and wait for stability
sync
sleep 2
sync

if rsync "${RSYNC_OPTS[@]}" "$TEMPLATE_ROOT/" "$ROOT_DIR/" >/dev/null; then
    # Force filesystem sync and wait for stability
    sync
    sleep 2
    sync
    rm -rf "$BACKUP_DIR"
else
    rsync_exit_code=$?
    echo "✗ Template sync failed with exit code $rsync_exit_code"
    echo "Debug info: Running rsync with verbose output for debugging:"
    rsync -av --delete --exclude-from="$TEMPLATE_ROOT/.ignore" "$TEMPLATE_ROOT/" "$ROOT_DIR/" || true
    echo "Restoring backup..."
    [ -d "$BACKUP_DIR" ] && { rm -rf "$ROOT_DIR"; mv "$BACKUP_DIR" "$ROOT_DIR"; }
    exit $rsync_exit_code
fi

# Set proper ownership and permissions
chown -R pcs:pcs "$ROOT_DIR"
find "$ROOT_DIR/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "✓ Template sync completed successfully"