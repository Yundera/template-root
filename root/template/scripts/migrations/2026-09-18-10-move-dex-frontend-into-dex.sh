#!/bin/bash

# Sweep the legacy $YND_ROOT/dex-frontend/ after the rendered Dex frontend moved
# to $YND_ROOT/dex/frontend/.
#
# NOTHING HERE MOVES ANY FILE. The frontend is rendered from the template on
# every self-check by tools/provision-dex-frontend.sh, which runs at
# ensure-dex.sh (scripts-config.txt step 71) — ahead of
# ensure-user-compose-stack-up.sh (step 80), which is what recreates `dex` onto
# the new bind sources because its volume list changed. So by the time the new
# compose file is applied the new directory already exists, fully populated,
# and the old one holds nothing that is not regenerated. Copying would only
# risk carrying a stale theme forward.
#
# WHY THE OLD DIRECTORY CAN BE DELETED WHILE DEX IS RUNNING. Migrations run from
# ensure-template-sync.sh (step 22), with the pre-move `dex` container still
# mounted on dex-frontend/. A bind mount follows the inode, not the path: the
# running container keeps serving the deleted files until it is recreated eight
# steps later, and the recreate resolves the new paths. This is the same inode
# property documented at length in tools/provision-dex-frontend.sh — there it is
# a trap, here it is what makes the sweep safe.
#
# Deliberately NOT a hard failure: an undeletable leftover is cosmetic, and a
# migration that exits non-zero aborts the whole template sync.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/yundera/migration-markers/$(basename "$0" .sh).marker"

YND_ROOT="/DATA/AppData/yundera"
OLD_FRONTEND="$YND_ROOT/dex-frontend"
NEW_FRONTEND="$YND_ROOT/dex/frontend"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

write_marker() {
    echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
    echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
    echo "Migration $MIGRATION_NAME completed successfully"
}

if [ ! -e "$OLD_FRONTEND" ]; then
    echo "$OLD_FRONTEND is already absent"
    write_marker
    exit 0
fi

# Guard against deleting the only copy on a box where, for whatever reason, the
# provisioning tool has not run yet (UPDATE_URL=local with a half-synced tree,
# an operator running migrations by hand). The next self-check renders the new
# location and this migration converges then — same "defer to a later cycle"
# shape as 2026-08-27-10-rename-dex-internal-network.sh.
if [ ! -f "$NEW_FRONTEND/templates/login.html" ]; then
    echo "Warning: $NEW_FRONTEND is not populated yet - leaving $OLD_FRONTEND for a later cycle"
    exit 0
fi

if rm -rf "$OLD_FRONTEND"; then
    echo "Removed legacy $OLD_FRONTEND (frontend now at $NEW_FRONTEND)"
    write_marker
else
    echo "Warning: could not remove $OLD_FRONTEND, leaving it for a later cycle"
fi

exit 0
