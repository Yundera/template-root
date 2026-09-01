#!/bin/bash

# Migration: bulk-copy the template root A -> B, once, ahead of the root move.
#
# Prepares `doc/root-migration.md` (`/DATA/AppData/casaos/apps/yundera` ->
# `/DATA/AppData/yundera`) by seeding Root B with a complete copy of Root A:
# the whole template tree plus the non-recomputable state (`.pcs.env`,
# `.pcs.secret.env`, `.ynd.user.env`, `.env`, `migration-markers/`, `log/*.log`,
# `*.backup`, `.self-check-cron-disabled`). Nothing reads Root B's copy yet —
# every script still points at Root A, and this migration does not change that.
# It only means that when the flip ships, Root B is already populated on every
# box and the flip cycle has a tree to chmod/execute against (step 4 of the doc's
# cutover sequence).
#
# THE COPY IS ADDITIVE — NO `--delete`. Root B already holds live runtime state
# that has no counterpart in Root A (`auth/` with the local account, `dex/`,
# `data/certs`, `admin/gate-data`, `perf/`, `onboarding/`,
# `.provisioning-in-progress`). A mirroring sync would delete all of it. The only
# names that collide are `docker-compose.yml` / `.env` / `auth/` — the first two
# are the mirror copies `ensure-maison-yundera-mirror.sh` rewrites from Root A on
# every cycle anyway, and `auth/` only gains `configuration.yml.tmpl` (inert:
# Authelia reads `/config/configuration.yml`, which `ensure-authelia.sh` renders).
#
# ONE-SHOT, SO ROOT B'S TREE FREEZES AT TODAY'S VERSION. That is intentional and
# harmless: nothing executes from Root B until the flip, and the flip's own
# `ensure-template-sync.sh` rsyncs the current tree into Root B on its first
# cycle. Root A stays authoritative throughout.
#
# NON-BLOCKING BY DESIGN. A failing migration aborts template sync fleet-wide,
# which is far worse than a deferred preparatory copy — so every problem here
# warns and exits 0 *without* the marker, and the next self-check cycle retries.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
OLD_ROOT="/DATA/AppData/casaos/apps/yundera"
NEW_ROOT="/DATA/AppData/yundera"
MARKER_FILE="$OLD_ROOT/migration-markers/$(basename "$0" .sh).marker"
NEW_MARKER_FILE="$NEW_ROOT/migration-markers/$(basename "$0" .sh).marker"

echo "Starting migration: $MIGRATION_NAME"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

write_markers() {
    mkdir -p "$(dirname "$MARKER_FILE")"
    {
        echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Migration: $MIGRATION_NAME"
        echo "Description: bulk copy $OLD_ROOT -> $NEW_ROOT (root move preparation)"
    } > "$MARKER_FILE"
    # Also drop the marker in Root B: once run-migrations.sh reads its markers
    # from there, this copy must not replay over the live tree.
    mkdir -p "$(dirname "$NEW_MARKER_FILE")"
    cp -a "$MARKER_FILE" "$NEW_MARKER_FILE" 2>/dev/null || true
}

if [ ! -d "$OLD_ROOT" ]; then
    echo "No template root at $OLD_ROOT - nothing to copy (fresh install)"
    write_markers
    echo "Migration $MIGRATION_NAME completed successfully"
    exit 0
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "Warning: rsync not available, deferring the copy to a later cycle"
    exit 0
fi

# Space check before touching anything: Root A and Root B share one filesystem
# (/DATA is a directory on /), so the copy roughly doubles the tree's footprint.
SRC_KB="$(du -sk "$OLD_ROOT" | cut -f1)"
mkdir -p "$NEW_ROOT"
AVAIL_KB="$(df -Pk "$NEW_ROOT" | awk 'NR==2 {print $4}')"
if [ -n "${AVAIL_KB:-}" ] && [ "$AVAIL_KB" -lt $(( SRC_KB * 12 / 10 )) ]; then
    echo "Warning: need ~$(( SRC_KB * 12 / 10 ))KB free for the copy, only ${AVAIL_KB}KB available - deferring"
    exit 0
fi

echo "Copying $OLD_ROOT -> $NEW_ROOT (${SRC_KB}KB, additive, no --delete)"
if ! rsync -a "$OLD_ROOT/" "$NEW_ROOT/"; then
    echo "Warning: copy failed, leaving $NEW_ROOT as-is and deferring to a later cycle"
    exit 0
fi

# Verify: everything that cannot be recomputed must have landed, with its mode
# intact (.pcs.secret.env is 600 and stays 600). Only files present in Root A are
# required in Root B - a box that never had .self-check-cron-disabled is fine.
missing=0
for rel in .pcs.env .pcs.secret.env .ynd.user.env .env docker-compose.yml \
           scripts/self-check.sh scripts/self-check-reboot.sh migration-markers; do
    if [ -e "$OLD_ROOT/$rel" ] && [ ! -e "$NEW_ROOT/$rel" ]; then
        echo "Warning: $rel did not reach $NEW_ROOT"
        missing=1
    fi
done

if [ -f "$OLD_ROOT/.pcs.secret.env" ]; then
    src_mode="$(stat -c '%a' "$OLD_ROOT/.pcs.secret.env")"
    dst_mode="$(stat -c '%a' "$NEW_ROOT/.pcs.secret.env" 2>/dev/null || echo "-")"
    if [ "$src_mode" != "$dst_mode" ]; then
        echo "Warning: .pcs.secret.env mode $src_mode != $dst_mode in $NEW_ROOT"
        missing=1
    fi
fi

if [ "$missing" -ne 0 ]; then
    echo "Warning: copy incomplete - not marking applied, will retry next cycle"
    exit 0
fi

write_markers
echo "Migration $MIGRATION_NAME completed successfully"
