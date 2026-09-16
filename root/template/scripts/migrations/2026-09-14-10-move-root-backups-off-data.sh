#!/bin/bash

# Migration: move the pre-sync stack-root copies off /DATA to /var/backups/yundera.
#
# ensure-template-sync.sh keeps the last few `cp -a` copies of $YND_ROOT so a sync
# that deletes the wrong subtree can be rolled back. They used to live at
# /DATA/AppData/.yundera-backups; they now live at /var/backups/yundera. See the
# BACKUP_ROOT block in ensure-template-sync.sh for the full reasoning — in short, a
# copy carries .pcs.secret.env, auth/secrets/, users_database.yml, dex.db and
# data/certs/key.pem, and under /DATA that tree is one Maison convention away from
# being listed as an app and one directory away from being shipped offsite in the
# nightly user-data set.
#
# This script only relocates what is already on the box. Nothing reads the old path
# afterwards, and the copies keep participating in the normal BACKUP_KEEP prune
# because the prune globs BACKUP_ROOT.
#
# THE MARKER IS CONDITIONAL, AND THAT IS THE WHOLE TRICK. Migrations run from the
# NEW template, early in ensure-template-sync.sh — but the script *executing* them
# is still the OLD copy on disk, which writes its own backup to the legacy path
# further down this same cycle, after we have finished. Writing the marker now
# would strand that one copy forever. So on the transition cycle we move what is
# there and defer; the next cycle runs the new script, finds nothing left to defer
# for, sweeps the straggler and marks. Same pattern as
# 2026-08-27-10-rename-dex-internal-network.sh.
#
# Best-effort throughout: a migration failure aborts template sync, and stale
# rollback copies are never worth blocking an update over.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/yundera/migration-markers/$(basename "$0" .sh).marker"

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
LEGACY_ROOT="/DATA/AppData/.yundera-backups"
BACKUP_ROOT="/var/backups/yundera"
INSTALLED_SYNC="$YND_TEMPLATE/scripts/self-check/ensure-template-sync.sh"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

if [ -d "$LEGACY_ROOT" ]; then
    moved=0
    for legacy_copy in "$LEGACY_ROOT"/root-backup-*; do
        [ -e "$legacy_copy" ] || continue
        target="$BACKUP_ROOT/$(basename "$legacy_copy")"
        if [ -e "$target" ]; then
            # Same epoch-stamped name on both sides: already relocated by an
            # earlier pass that then deferred. The new root wins.
            rm -rf "$legacy_copy"
            continue
        fi
        if mv "$legacy_copy" "$target"; then
            moved=$((moved + 1))
        else
            echo "Warning: could not move $legacy_copy - leaving it for a later cycle"
        fi
    done
    echo "Moved $moved backup(s) from $LEGACY_ROOT to $BACKUP_ROOT"
else
    echo "$LEGACY_ROOT is already absent"
fi

# See the ordering note at the top: the script running us may still be the old one.
# Match the assignment, not the path: the new script names the old location in its
# own comments, and a loose grep would defer every cycle forever.
if [ -f "$INSTALLED_SYNC" ] && grep -qE '^BACKUP_ROOT=.*\.yundera-backups' "$INSTALLED_SYNC"; then
    # LEAVE THE DIRECTORY. The old script fixed its BACKUP_DIR under $LEGACY_ROOT
    # before it called us and runs `cp -a "$YND_ROOT" "$BACKUP_DIR"` further down
    # this same cycle. cp does not create a missing grandparent, so removing the
    # directory here makes that copy fail — and the script runs under `set -e`, so
    # the sync aborts, the new script never lands, and the next cycle repeats it.
    # That is a wedged box, not a slow convergence.
    mkdir -p "$LEGACY_ROOT"
    echo "The installed ensure-template-sync.sh still writes to $LEGACY_ROOT - leaving the directory and deferring the marker to the next cycle"
    exit 0
fi

# The installed script writes to $BACKUP_ROOT now, so nothing will put anything
# back here.
if [ -d "$LEGACY_ROOT" ]; then
    if rmdir "$LEGACY_ROOT" 2>/dev/null; then
        echo "Removed $LEGACY_ROOT"
    else
        echo "Warning: $LEGACY_ROOT is not empty - leaving it in place"
    fi
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
exit 0
