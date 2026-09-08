#!/bin/bash

# Migration: move the template root out of the CasaOS app folder.
#
# (No apostrophes in the line above: run-migrations.sh pipes it through `xargs`
# to build the marker description, and an unmatched quote makes xargs complain
# into every box's log.)
#
#   Root A  /DATA/AppData/casaos/apps/yundera   (from here on: stale, kept)
#   Root B  /DATA/AppData/yundera               (from here on: authoritative)
#
# See doc/root-migration.md. This is the cutover. A 2026-09-01 preparation
# migration (retired in the same push as this one shipped) had already put a
# copy of the tree in Root B on every box in the fleet, frozen at that date —
# which is why the idempotency note below matters. This script does not depend
# on that copy: it seeds everything itself.
#
# WHAT MAKES THIS SAFE IS THAT ROOT A IS NEVER TOUCHED. It is left complete and
# stale, which is both the rollback path (point the cron back at it) and the
# reason `rm -rf` anywhere under casaos/ can only ever destroy a dead copy.
# Cleaning it up is not planned: it becomes static data nobody reads.
#
# THE CYCLE THIS RUNS IN — the ordering is the whole design:
#
#   cycle N   the OLD ensure-template-sync.sh is executing (its YND_ROOT is
#             Root A). It downloads the new tree and runs migrations FROM IT,
#             i.e. this script. We seed Root B here — tree, env, markers —
#             because the old rsync that follows writes only Root A.
#             The rest of cycle N then runs the NEW scripts (delivered into
#             Root A by that rsync), and those read and write Root B. That is
#             why seeding the tree is not optional: ensure-self-check-at-reboot.sh
#             does `chmod +x` on a Root B path under `set -e`, and every other
#             ensure script sources Root B's library/log.sh.
#             Both cron entries are repointed at Root B later in the same cycle.
#
#   cycle N+1 cron runs Root B's self-check.sh; the new ensure-template-sync.sh
#             syncs into Root B. Root A stops changing.
#
# IDEMPOTENCY IS NOT "DOES ROOT B HAVE A TREE". It does — the 2026-09-01 prep
# copy put one there on every box in the fleet, frozen at that date. A guard
# phrased that way (as doc/root-migration.md originally specified) would exit 0
# on the first box that ran it, the runner would write the marker, and the box
# would then be running new scripts against a week-old tree. The marker is the
# guard, and it is checked in Root A, which is where every box that has already
# flipped certainly has one.
#
# FAILS LOUD. A non-zero exit here aborts template sync, so the box keeps
# running Root A and updates stop until someone looks — which is the right
# direction: the alternative is a half-populated Root B that the rest of the
# cycle then executes against.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
OLD_ROOT="/DATA/AppData/casaos/apps/yundera"
NEW_ROOT="/DATA/AppData/yundera"
MARKER_FILE="$OLD_ROOT/migration-markers/$(basename "$0" .sh).marker"
NEW_MARKER_FILE="$NEW_ROOT/migration-markers/$(basename "$0" .sh).marker"

# The tree this migration was unpacked from: <tree>/root/scripts/migrations/<me>.
# Under UPDATE_URL=local|frozen that resolves to Root A's own tree, which is the
# correct source there too.
TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Starting migration: $MIGRATION_NAME"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

if [ ! -d "$OLD_ROOT" ]; then
    # A fresh install: pcs-init.sh relocates the orchestrator's staged env files
    # into Root B itself and there has never been a Root A. Nothing to move.
    echo "No $OLD_ROOT on this host (fresh install) - nothing to move"
    mkdir -p "$(dirname "$NEW_MARKER_FILE")"
    printf 'Migration completed at: %s\nMigration: %s\nDescription: fresh install, no Root A to move\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MIGRATION_NAME" > "$NEW_MARKER_FILE"
    exit 0
fi

if [ ! -f "$TEMPLATE_ROOT/.ignore" ]; then
    echo "ERROR: no .ignore at $TEMPLATE_ROOT — cannot seed $NEW_ROOT safely"
    exit 1
fi

command -v rsync >/dev/null 2>&1 || {
    echo "ERROR: rsync is not installed; cannot seed $NEW_ROOT"
    exit 1
}

mkdir -p "$NEW_ROOT"

# ---------------------------------------------------------------------------
# 1. Markers FIRST, before anything can read them.
#
# run-migrations.sh reads its markers from Root B from this template onwards. A
# Root B that is missing one replays that migration — and the set includes
# 2026-08-02-14-remove-casaos-stack.sh, which runs `docker compose down`. The
# prep copy already placed a set here; refresh it so anything applied since is
# represented. Additive: `cp -a` per file, never a delete.
# ---------------------------------------------------------------------------
if [ -d "$OLD_ROOT/migration-markers" ]; then
    mkdir -p "$NEW_ROOT/migration-markers"
    cp -a "$OLD_ROOT/migration-markers/." "$NEW_ROOT/migration-markers/" || {
        echo "ERROR: could not copy migration markers to $NEW_ROOT"
        exit 1
    }
    echo "Markers refreshed in $NEW_ROOT/migration-markers"
fi

# ---------------------------------------------------------------------------
# 2. The non-recomputable state, from the LIVE root.
#
# Root B's copies are the prep migration's, frozen at 2026-09-01 and stale by
# every value that has changed since — UPDATE_URL, LOCAL_ADMIN_USER, the backup
# credentials, a rotated USER_JWT. These overwrite unconditionally: Root A is
# the live root right up until this script runs.
#
# `cp -a` preserves mode and owner, which matters for .pcs.secret.env (600).
# ---------------------------------------------------------------------------
for f in .pcs.env .pcs.secret.env .ynd.user.env .env .self-check-cron-disabled; do
    if [ -f "$OLD_ROOT/$f" ]; then
        cp -a "$OLD_ROOT/$f" "$NEW_ROOT/$f" || {
            echo "ERROR: could not copy $f into $NEW_ROOT"
            exit 1
        }
    fi
done
echo "Env files copied from $OLD_ROOT"

# History and rollback copies. Best-effort: a missing log is not a reason to
# strand the fleet on the old root.
mkdir -p "$NEW_ROOT/log"
cp -a "$OLD_ROOT"/log/*.log "$NEW_ROOT/log/" 2>/dev/null || true
cp -a "$OLD_ROOT"/*.backup "$NEW_ROOT/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. The tree itself, from the template being installed.
#
# NO --delete, and the template's own .ignore as the exclude list: Root B holds
# live runtime state (auth/, dex/, data/, admin/, onboarding/) that the same
# list protects during every ordinary sync. Step 2's files are in that list too,
# which is why they are copied explicitly above rather than left to this.
# ---------------------------------------------------------------------------
if ! rsync -a --exclude-from="$TEMPLATE_ROOT/.ignore" "$TEMPLATE_ROOT/" "$NEW_ROOT/"; then
    echo "ERROR: could not seed the template tree into $NEW_ROOT"
    exit 1
fi

# The exec bits: ensure-template-sync.sh sets them on its source, but that runs
# after migrations, and the rest of THIS cycle already executes from Root B.
find "$NEW_ROOT/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
chown -R pcs:pcs "$NEW_ROOT" 2>/dev/null || true
echo "Template tree seeded into $NEW_ROOT"

# ---------------------------------------------------------------------------
# 4. The tile icon, the one job ensure-maison-yundera-mirror.sh had left.
#
# Maison renders a managed app's tile from `.icon.<ext>` beside its compose, in
# preference to the compose's icon: URL — which is what keeps the Settings tile
# from going blank on an offline box.
# ---------------------------------------------------------------------------
if [ -f "$NEW_ROOT/icon.svg" ]; then
    cp -a "$NEW_ROOT/icon.svg" "$NEW_ROOT/.icon.svg"
    chown pcs:pcs "$NEW_ROOT/.icon.svg" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 5. Verify before claiming the flip. Everything the next script in this cycle
#    will reach for must be present and executable, and .pcs.secret.env must
#    still be 600 — a world-readable copy of USER_JWT and DEFAULT_PWD is its own
#    incident.
# ---------------------------------------------------------------------------
fail=0
for rel in .pcs.env .pcs.secret.env .ynd.user.env docker-compose.yml \
           scripts/self-check.sh scripts/self-check-reboot.sh \
           scripts/library/log.sh scripts/tools/env-file-manager.sh; do
    if [ ! -e "$NEW_ROOT/$rel" ]; then
        echo "ERROR: $rel is missing from $NEW_ROOT"
        fail=1
    fi
done
for rel in scripts/self-check.sh scripts/self-check-reboot.sh scripts/tools/env-file-manager.sh; do
    if [ -e "$NEW_ROOT/$rel" ] && [ ! -x "$NEW_ROOT/$rel" ]; then
        echo "ERROR: $rel is not executable in $NEW_ROOT"
        fail=1
    fi
done
if [ -f "$OLD_ROOT/.pcs.secret.env" ]; then
    src_mode="$(stat -c '%a' "$OLD_ROOT/.pcs.secret.env")"
    dst_mode="$(stat -c '%a' "$NEW_ROOT/.pcs.secret.env" 2>/dev/null || echo '-')"
    if [ "$src_mode" != "$dst_mode" ]; then
        echo "ERROR: .pcs.secret.env mode $src_mode != $dst_mode in $NEW_ROOT"
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "ERROR: $NEW_ROOT is incomplete — aborting the sync and leaving $OLD_ROOT authoritative"
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Mark applied, in BOTH roots.
#
# Root A's marker is the one this script's own guard reads — it is the copy that
# is certainly there on a box that has already flipped, whatever happens to
# Root B afterwards. Root B's is what run-migrations.sh reads from now on.
# ---------------------------------------------------------------------------
write_marker() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    {
        echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Migration: $MIGRATION_NAME"
        echo "Description: template root moved $OLD_ROOT -> $NEW_ROOT (Root A left in place, stale)"
    } > "$file"
}
write_marker "$MARKER_FILE"
write_marker "$NEW_MARKER_FILE"

echo "Migration $MIGRATION_NAME completed successfully"
