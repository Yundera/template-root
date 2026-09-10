#!/bin/bash

# Download template from GitHub repository and sync with local root directory
# This script reads UPDATE_URL from environment files and syncs the entire template

set -e

# Check for root privileges
[ "$EUID" -eq 0 ] || { echo "✗ This script must be run as root"; exit 1; }

YND_ROOT="/DATA/AppData/yundera"

# Install required tools
"$YND_ROOT/scripts/tools/ensure-packages.sh" wget curl apt-utils unzip rsync

# Configuration
DEFAULT_TEMPLATE_URL="https://github.com/Yundera/template-root/archive/refs/heads/stable.zip"
ENV_FILE="$YND_ROOT/.pcs.env"
TEMP_DIR=$(mktemp -d)
# Pre-sync copies of the stack root. On /DATA so they survive the reboot that
# usually follows an update, and kept rather than deleted on success — see the
# note at the `cp -a` below.
BACKUP_ROOT="/DATA/AppData/.yundera-backups"
BACKUP_KEEP=3
BACKUP_DIR="$BACKUP_ROOT/root-backup-$(date +%s)"
mkdir -p "$BACKUP_ROOT"

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
UPDATE_URL=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get UPDATE_URL "$ENV_FILE")
[ -z "$UPDATE_URL" ] && UPDATE_URL="$DEFAULT_TEMPLATE_URL"

echo "→ Using update URL: $UPDATE_URL"

# Handle the two "do not download" modes.
#
#   local    a developer is testing hand-placed scripts on this box
#   frozen   the owner opted out of automated updates
#            (scripts/tools/feature-platform-updates.sh writes this one)
#
# Identical behaviour, deliberately distinct values: collapsing them would leave
# support unable to tell a dev box from a user's choice, since the file would
# look the same either way. Migrations still run in both — markers make them
# one-shot, and a box that skips them would drift from its own on-disk template.
if [ "$UPDATE_URL" = "local" ] || [ "$UPDATE_URL" = "frozen" ]; then
    echo "→ ${UPDATE_URL} mode: skipping download, running migrations..."
    
    # Run migrations from local template
    if ! run_migrations "$YND_ROOT"; then
        exit 1
    fi
    
    echo "✓ Template sync completed successfully (${UPDATE_URL} mode)"
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

# Create backup if root directory exists.
#
# ON /DATA, NOT /tmp, AND KEPT. This used to write to /tmp/root-backup-<epoch>
# and delete it the moment rsync exited 0 — so a sync that succeeded while
# removing the wrong subtree left nothing to recover from, and /tmp is cleared
# by the reboot that usually follows. Since the root move the destination holds
# the local account and Dex's store, so the copy is worth its disk. Only the
# most recent BACKUP_KEEP are retained.
[ -d "$YND_ROOT" ] && cp -a "$YND_ROOT" "$BACKUP_DIR"

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
mkdir -p "$YND_ROOT"

# ---------------------------------------------------------------------------
# DELETE GUARD — dry-run first, and refuse to sync if `--delete` would touch
# anything that is not ours to delete.
#
# Since the root move, $YND_ROOT is both the template tree AND the stack's live
# state: auth/ (the owner's only local credential), dex/, data/certs, admin/.
# All of it is protected by .ignore — and the whole protection is one file that
# a future edit can silently break. `--delete` gives no warning and no second
# chance, so this converts "a pattern went missing" from total loss into a
# refusal to sync.
#
# Deliberately a hard exit rather than a filtered sync: if the exclude list is
# wrong we do not know what else it is wrong about, and a PCS running last
# week's template is a far better outcome than one missing its user database.
# ---------------------------------------------------------------------------
PROTECTED_RE='^(auth|dex|dex-frontend|data|admin|onboarding(\.d)?|log|migration-markers)(/|$)|^\.(env|pcs\.env|pcs\.secret\.env|ynd\.user\.env|provisioning-in-progress|self-check-cron-disabled|icon\.svg|casaos-mirror)$'
DEL_LIST=$(rsync "${RSYNC_OPTS[@]}" --dry-run --itemize-changes \
               "$TEMPLATE_ROOT/" "$YND_ROOT/" 2>/dev/null \
           | sed -n 's/^\*deleting  *//p' || true)

if [ -n "$DEL_LIST" ]; then
    OFFENDING=$(printf '%s\n' "$DEL_LIST" | grep -E "$PROTECTED_RE" || true)
    if [ -n "$OFFENDING" ]; then
        echo "✗ REFUSING SYNC: --delete would remove protected state under $YND_ROOT"
        printf '%s\n' "$OFFENDING" | sed 's/^/    /'
        echo "  Check $TEMPLATE_ROOT/.ignore — every path above should be excluded."
        rm -rf "$BACKUP_DIR"
        exit 1
    fi
fi

# Set exec bits on the SOURCE before syncing. The chmod at the end of this
# script leaves a window in which the newly-synced scripts are on disk but not
# executable — and this rsync runs *inside* the self-check loop, which is
# iterating over those very scripts. Same failure mode that broke first-install
# on 2026-08-23 ("Script is not executable" / exit 126).
find "$TEMPLATE_ROOT/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Force filesystem sync and wait for stability
sync
sleep 2
sync

if rsync "${RSYNC_OPTS[@]}" "$TEMPLATE_ROOT/" "$YND_ROOT/" >/dev/null; then
    # Force filesystem sync and wait for stability
    sync
    sleep 2
    sync
    # Keep this backup and prune the oldest. `ls -1d` sorts the epoch-suffixed
    # names lexically, which for a fixed-width epoch is chronological.
    ls -1d "${BACKUP_ROOT}"/root-backup-* 2>/dev/null \
        | head -n -"$BACKUP_KEEP" \
        | xargs -r rm -rf
else
    rsync_exit_code=$?
    echo "✗ Template sync failed with exit code $rsync_exit_code"
    echo "Debug info: Running rsync with verbose output for debugging:"
    rsync -av --delete --exclude-from="$TEMPLATE_ROOT/.ignore" "$TEMPLATE_ROOT/" "$YND_ROOT/" || true
    echo "Restoring backup..."
    [ -d "$BACKUP_DIR" ] && { rm -rf "$YND_ROOT"; mv "$BACKUP_DIR" "$YND_ROOT"; }
    exit $rsync_exit_code
fi

# Set proper ownership and permissions
chown -R pcs:pcs "$YND_ROOT"
find "$YND_ROOT/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "✓ Template sync completed successfully"