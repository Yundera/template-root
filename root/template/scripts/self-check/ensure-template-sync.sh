#!/bin/bash

# Download template from GitHub repository and sync with local root directory
# This script reads UPDATE_URL from environment files and syncs the entire template

set -e

# Check for root privileges
[ "$EUID" -eq 0 ] || { echo "✗ This script must be run as root"; exit 1; }

# TWO ROOTS, AND THE SPLIT IS THE POINT.
#
#   $YND_ROOT      the stack's live state, and the app folder Maison manages.
#                  auth/, dex/, dex-frontend/, data/, admin/, onboarding*/,
#                  log/, migration-markers/, the .pcs*.env files. NEVER a
#                  --delete target.
#   $YND_TEMPLATE  the template tree, and nothing else. Owned wholesale by this
#                  script, contains no state, and is therefore safe to sync with
#                  --delete.
#
# Between the 2026-09-08 root move and this change the two were the SAME
# directory, and `rsync -a --delete` ran over all of it. The only thing keeping
# it from deleting the owner's Authelia database was root/.ignore, a hand-kept
# exclude list, so a dropped line was a fleet-wide data-loss bug.
#
# THE SECOND OPINION THAT COULD NOT BE ONE. This script used to carry a delete
# guard for that: a PROTECTED_RE naming the same paths as .ignore, matched
# against a `--dry-run --itemize-changes` delete list, hard-exiting if the two
# disagreed. It could not be a second opinion, because the two halves came from
# different releases — .ignore is read from the template just downloaded, while
# PROTECTED_RE lived in the copy of this script already on disk. It never
# compared a release against itself, only new .ignore against old regex, so the
# one thing it reliably detected was its own maintainers retiring a path.
#
# Which is what it did. Dropping `.casaos-mirror` from both files in one commit
# (a6bcc61) DEADLOCKED every box carrying that marker: the new .ignore put it in
# the delete list, the old on-disk regex still protected it, refuse — and since
# the refusal is what stops the sync, the script carrying the stale regex could
# never be replaced. Unrecoverable without a manual `rm` on each box. Seen on
# wisera 2026-09-16, and removed the same day (cbac878).
#
# That failure is the strongest argument for this split. A guard whose halves
# straddle a release boundary is a liability; a --delete that cannot reach live
# state in the first place needs no guard, no exclude list, and no lockstep
# between two files. Retiring a path is now deleting it from the template.
#
# See doc/root-migration.md for the move that created the overlap and
# doc/template-subtree.md for the one that ended it.
YND_ROOT="/DATA/AppData/yundera"
YND_TEMPLATE="$YND_ROOT/template"

# Install required tools
"$YND_TEMPLATE/scripts/tools/ensure-packages.sh" wget curl apt-utils unzip rsync

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
UPDATE_URL=$("$YND_TEMPLATE/scripts/tools/env-file-manager.sh" get UPDATE_URL "$ENV_FILE")
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
    
    # Run migrations from the local template tree, not from $YND_ROOT: since the
    # subtree split the migrations live under template/ like everything else the
    # template owns.
    if ! run_migrations "$YND_TEMPLATE"; then
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

# The subtree this script syncs with --delete. Checked BEFORE anything is
# touched: `rsync --delete` with a missing source errors out rather than
# emptying the destination, but relying on that is relying on rsync's choice of
# failure mode for the one operation that could still wipe the tree. Say it out
# loud instead.
SRC_TEMPLATE="$TEMPLATE_ROOT/template"
if [ ! -d "$SRC_TEMPLATE" ]; then
    echo "✗ Downloaded tree has no template/ directory — refusing to sync"
    echo "  This build predates the template-subtree split (doc/template-subtree.md),"
    echo "  or the archive is truncated. Top level of the downloaded tree:"
    ls -A "$TEMPLATE_ROOT" | sed 's/^/    /'
    exit 1
fi

# BACKUP FIRST, THEN MIGRATE. The reverse was the order until 2026-09-16: the
# copy was taken after run_migrations, so the "pre-sync" backup was really a
# post-migration one and a migration that corrupted the root had already been
# baked into the only copy of it. Migrations are the most dangerous thing this
# script runs — they are arbitrary shell, written once, executed fleet-wide —
# so they are exactly what the copy needs to sit in front of.
[ -d "$YND_ROOT" ] && cp -a "$YND_ROOT" "$BACKUP_DIR"

# Run migrations from the new template before syncing
if ! run_migrations "$SRC_TEMPLATE"; then
    echo "✗ Template sync aborted due to migration failure."
    exit 1
fi

# Set exec bits on the SOURCE before syncing. Setting them on the destination
# afterwards leaves a window in which the newly-synced scripts are on disk but
# not executable — and this rsync runs *inside* the self-check loop, which is
# iterating over those very scripts. Same failure mode that broke first-install
# on 2026-08-23 ("Script is not executable" / exit 126).
find "$SRC_TEMPLATE/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Force filesystem sync and wait for stability
sync
sleep 2
sync

# ---------------------------------------------------------------------------
# THE SYNC. Three commands, and only the first one deletes.
#
#   1. template/ — the whole template tree, --delete so a retired script stops
#      running on the fleet. Safe because NOTHING writes state here; the
#      destination is disposable by construction and this script is its only
#      writer. That is the entire argument, and it is a property of the layout
#      rather than of an exclude list somebody has to maintain correctly.
#
#   2. docker-compose.yml and 3. .icon.svg — the two files Maison needs at the
#      app-folder root to render this stack as a managed app (maison
#      docs/app-model.md). They cannot live under template/, so they sit at the
#      repo's tree root and are delivered individually, with no --delete
#      anywhere near them.
#
# rsync renames a single-file source onto a destination path that does not end
# in `/`, which is how icon.svg becomes .icon.svg without a second `cp` step.
# Maison prefers `.icon.<ext>` beside the compose over the compose's `icon:`
# URL, which is what keeps the Settings tile from going blank on an offline box
# or a moved repo path.
# ---------------------------------------------------------------------------
echo "→ Syncing template subtree..."
mkdir -p "$YND_TEMPLATE"

if rsync -a --delete "$SRC_TEMPLATE/" "$YND_TEMPLATE/" >/dev/null \
   && rsync -a "$TEMPLATE_ROOT/docker-compose.yml" "$YND_ROOT/" \
   && rsync -a "$TEMPLATE_ROOT/icon.svg" "$YND_ROOT/.icon.svg"; then
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
    rsync -av --delete "$SRC_TEMPLATE/" "$YND_TEMPLATE/" || true
    echo "Restoring template subtree from backup..."
    # RESTORE ONLY WHAT WE TOUCHED. This used to be
    # `rm -rf "$YND_ROOT"; cp -a "$BACKUP_DIR" "$YND_ROOT"` — a full rollback of
    # the stack root, which threw away every byte of state written since the copy
    # was taken minutes earlier: Authelia sessions, dex.db rows, a freshly issued
    # certificate. That was defensible only while the template tree and the state
    # lived in the same directory and a failed sync could have mangled either.
    # It cannot now: the only thing this script can damage is template/.
    #
    # COPY, DO NOT MOVE. `mv` across a filesystem boundary is a real copy that
    # consumes the source as it goes, so a failure halfway would leave the tree
    # incomplete AND the only pre-sync copy of it half-deleted. BACKUP_ROOT is on
    # the same filesystem today, but nothing in this script enforces that, and a
    # failed sync is exactly the moment to keep the copy rather than spend it.
    if [ -d "$BACKUP_DIR/template" ]; then
        rm -rf "$YND_TEMPLATE"
        cp -a "$BACKUP_DIR/template" "$YND_TEMPLATE"
    else
        # No template/ in the backup means this box had not been split yet, so
        # there is nothing to roll back to — the legacy tree at $YND_TEMPLATE/scripts
        # is untouched and still the one cron runs. Leave it alone and let the
        # next cycle retry.
        echo "  (backup predates the subtree split — legacy tree left in place)"
    fi
    exit $rsync_exit_code
fi

# Set proper ownership and permissions.
#
# Recursive over the whole root, not just template/: the synced files arrive
# root-owned and several containers read the state directories as uid 1000.
# Last, because under `set -e` it is the only remaining step that can abort the
# script.
chown -R pcs:pcs "$YND_ROOT"
find "$YND_TEMPLATE/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "✓ Template sync completed successfully"
