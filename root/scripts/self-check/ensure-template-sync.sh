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
# Pre-sync copies of the stack root. On the OS disk, under Debian's own namespace
# for previous versions of system files — dpkg and apt keep theirs right beside
# ours — so they survive the reboot that usually follows an update, and kept
# rather than deleted on success. See the note at the `cp -a` below.
#
# NOT UNDER /DATA, AND THE REASONS ARE LOAD-BEARING. A copy carries the whole
# root: .pcs.secret.env, auth/secrets/, auth/users_database.yml, dex.db and
# data/certs/key.pem.
#
#   * Anywhere under /DATA outside AppData/ is inside Maison's user-data backup
#     set — its exclusions are exactly `/AppData/`, `**/cache/`, `**/logs/`
#     (maison internal/backup/kopia: UserDataExclusions) — so copies there would
#     be shipped offsite every night: the secrets above, plus two live SQLite
#     databases, which that set explicitly must not carry because an engine
#     reading a file mid-write captures it mid-write.
#   * Under /DATA/AppData/ the only thing keeping a directory of stack copies off
#     the dashboard is Maison's "a dot in the name is not an app" convention — a
#     rule owned by another component, on a name we do not control. This directory
#     used to be /DATA/AppData/.yundera-backups, one letter away from the
#     .backups/ Maison used to keep beside the apps (it has since moved into
#     /DATA/AppData/maison/.backups/, so that particular near-collision is gone —
#     the reason for leaving AppData/ is not);
#     2026-09-14-10-move-root-backups-off-data.sh moves what is already there.
#
# /DATA is a directory on /, not a mountpoint, so this is the same filesystem as
# $YND_ROOT and nothing about the copy or the restore changes. The root is ~6 MB,
# so BACKUP_KEEP copies cost ~17 MB.
BACKUP_ROOT="/var/backups/yundera"
BACKUP_KEEP=3
BACKUP_DIR="$BACKUP_ROOT/root-backup-$(date +%s)"
mkdir -p "$BACKUP_ROOT"
# 0700: the copies hold secrets, and unlike the files inside them (`cp -a`
# preserves those modes) the directory itself is created here, under the
# self-check's umask.
chmod 700 "$BACKUP_ROOT"

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
# PERSISTENT, NOT /tmp, AND KEPT. This used to write to /tmp/root-backup-<epoch>
# and delete it the moment rsync exited 0 — so a sync that succeeded while
# removing the wrong subtree left nothing to recover from, and /tmp is cleared
# by the reboot that usually follows. Since the root move the destination holds
# the local account and Dex's store, so the copy is worth its disk. Only the
# most recent BACKUP_KEEP are retained. BACKUP_ROOT above carries why the
# destination is on the OS disk rather than under /DATA.
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
# THERE IS NO DELETE GUARD HERE, AND THAT IS DELIBERATE (removed 2026-09-16).
#
# There used to be one: a PROTECTED_RE naming the same paths as root/.ignore,
# matched against a `--dry-run --itemize-changes` delete list, hard-exiting if
# the two ever disagreed. It was meant as a second opinion on .ignore. It could
# not be one, because the two halves came from different releases: .ignore is
# read from the template we just downloaded, while PROTECTED_RE lives in the
# copy of THIS script already on disk, i.e. the previous release. So the guard
# never compared a release against itself — it compared new .ignore against old
# regex, and the only thing it could reliably detect was its own maintainers
# retiring a path.
#
# Which is exactly what it did. Dropping `.casaos-mirror` from both files in one
# commit (a6bcc61) deadlocked every box carrying that marker: the new .ignore put
# it in the delete list, the old on-disk regex still protected it, refuse — and
# since the refusal is what stops the sync, the script carrying the stale regex
# could never be replaced. Unrecoverable without a manual `rm` on each box. Seen
# on wisera 2026-09-16.
#
# What actually protects the live state is root/.ignore, and the pre-sync copy of
# the whole root taken above into $BACKUP_DIR — which, unlike the guard, is kept
# on success, survives the reboot, and covers every failure mode rather than the
# one the regex author thought of. Retiring a path is now a single edit to
# .ignore, with no second file to keep in lockstep and no cross-release trap.
# ---------------------------------------------------------------------------

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
    # COPY, DO NOT MOVE. `mv` across a filesystem boundary is a real copy that
    # consumes the source as it goes, so a failure halfway would leave the root
    # incomplete AND the only pre-sync copy of it half-deleted. BACKUP_ROOT is on
    # the same filesystem today, but nothing in this script enforces that, and a
    # failed sync is exactly the moment to keep the copy rather than spend it.
    [ -d "$BACKUP_DIR" ] && { rm -rf "$YND_ROOT"; cp -a "$BACKUP_DIR" "$YND_ROOT"; }
    exit $rsync_exit_code
fi

# The Settings tile's icon. Maison renders a managed app's tile from `.icon.<ext>`
# beside its compose in preference to the compose's `icon:` URL, which is what keeps
# the tile from going blank on an offline box or a moved repo path.
#
# This used to be step 4 of migrations/2026-09-08-12-move-root-to-maison.sh (retired
# 2026-09-15), which meant it only ever ran on boxes that flipped: that migration
# returned early on the fresh-install branch, so no PCS created after the move was
# ever given one. It belongs here — `icon.svg` arrives with the sync above and
# `.icon.svg` is derived from it, so the pair converges on every box, every cycle.
# `.icon.svg` is excluded from the sync itself (root/.ignore), so rsync will not
# delete what we write here.
#
# ABOVE the chown below, not after it: this script runs under `set -e`, and the
# recursive chown is the last thing that can abort it. Placed here the icon is
# already in place when that runs, and it picks up pcs:pcs from the same sweep.
if [ -f "$YND_ROOT/icon.svg" ] && ! cmp -s "$YND_ROOT/icon.svg" "$YND_ROOT/.icon.svg"; then
    cp -a "$YND_ROOT/icon.svg" "$YND_ROOT/.icon.svg"
    echo "✓ Settings tile icon refreshed (.icon.svg)"
fi

# Set proper ownership and permissions
chown -R pcs:pcs "$YND_ROOT"
find "$YND_ROOT/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "✓ Template sync completed successfully"