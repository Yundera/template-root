#!/bin/bash

# Migration: hand the running self-check over to the new template/ subtree.
#
# Companion to doc/template-subtree.md. The template tree moved from
# /DATA/AppData/yundera/<...> to /DATA/AppData/yundera/template/<...> so that
# `rsync --delete` stops pointing at the directory that holds the owner's
# Authelia database. This script is the one-cycle bridge between the two layouts.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY A MIGRATION IS NEEDED AT ALL, AND WHY IT COPIES SCRIPTS
#
# A self-updating tree cannot change its own location in one step: the script
# performing the sync is the OLD copy on disk, and the cron entry that will fire
# next was written by the OLD ensure-nightly-self-check.sh. On the transition
# cycle the box therefore looks like this:
#
#   step 5   ensure-template-sync.sh (OLD)  → downloads the new tree, runs us,
#                                             then rsyncs it into $YND_ROOT/
#   step 13  ensure-self-check-at-reboot.sh (OLD, from $YND_ROOT/scripts/)
#   step 14  ensure-nightly-self-check.sh   (OLD, from $YND_ROOT/scripts/)
#
# Steps 13 and 14 are the trap. They are marker-managed and rewrite their cron
# entries on every tick, so an OLD copy running at step 14 puts the cron line
# back to $YND_ROOT/scripts/self-check.sh — undoing any cron flip we performed
# at step 5, in the same cycle, silently. Flipping cron here would therefore be
# useless.
#
# So we do not flip cron. We replace the script tree those steps are read from,
# and let the NEW copies of steps 13/14 write the new path themselves, at their
# normal place in the run. Cron converges by the mechanism that already owns it
# rather than by a second mechanism racing it, and it keeps converging on every
# later cycle without any help from us.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY .always.sh RATHER THAN A MARKER
#
# The obvious shape here is a one-shot with the "defer the marker to the next
# cycle" trick used by 2026-09-14-10-move-root-backups-off-data.sh. It does not
# work: run-migrations.sh writes the marker itself for ANY migration that exits
# 0 (see its `if [[ "$migration_file" != *.always.sh ]]` block), so a migration
# that deliberately exits 0 without marking gets marked anyway and never runs
# again. The deferral in that 2026-09-14 script is already defeated for this
# reason and the fleet carries the false marker.
#
# `.always.sh` is the suffix run-migrations.sh exempts from marker tracking
# entirely. That is the right tool regardless: this is a convergent reconciler,
# not a one-shot, and the guard below is what makes it a no-op — on a box that
# has already crossed over, and on every box built after the split.
#
# PERMANENT — do not schedule its removal. A box can arrive on the pre-split
# layout months from now (frozen updates, powered off, old image), and this is
# the only thing that lets it cross. See root/scripts/README.MD.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"

YND_ROOT="/DATA/AppData/yundera"
LEGACY_SCRIPTS="$YND_ROOT/scripts"
INSTALLED_SYNC="$LEGACY_SCRIPTS/self-check/ensure-template-sync.sh"

echo "Starting migration: $MIGRATION_NAME"

# Locate the tree we were invoked from. We are run from two different depths
# depending on which runner picked us up, so derive it rather than assume:
#
#   old runner, top-level shim   <root>/scripts/migrations/     → <root>/template/scripts
#   new runner, post-split tree  <root>/template/scripts/migrations/ → <root>/template/scripts
#
# Both resolve to the same place; only the offset differs.
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$BASE/template/scripts" ]; then
    NEW_SCRIPTS="$BASE/template/scripts"
elif [ -d "$BASE/scripts" ]; then
    NEW_SCRIPTS="$BASE/scripts"
else
    echo "Cannot locate the new script tree from $BASE — nothing to do"
    exit 0
fi

# A box with no legacy tree is either freshly built or already crossed over.
if [ ! -d "$LEGACY_SCRIPTS" ]; then
    echo "No legacy tree at $LEGACY_SCRIPTS — box is already on the subtree layout"
    exit 0
fi

# THE GUARD. Match on the two-roots split that only the post-change script has,
# not on a path string: the new script names the legacy location in its own
# comments, and a loose grep would re-copy on every cycle forever.
if [ -f "$INSTALLED_SYNC" ] && grep -qE '^YND_TEMPLATE=' "$INSTALLED_SYNC"; then
    echo "Legacy tree at $LEGACY_SCRIPTS already carries the post-split scripts — nothing to do"
    exit 0
fi

# Refresh the legacy tree in place so the REST OF THIS CYCLE runs the new
# scripts. Deliberately no --delete: a straggler in the legacy tree is harmless
# (nothing will read it after this cycle, and R3 removes the directory outright),
# whereas --delete here would be the same mistake this whole change exists to
# undo — pointing a destructive rsync at a directory whose contents we do not
# fully own, while the self-check loop is walking it.
echo "Refreshing $LEGACY_SCRIPTS from $NEW_SCRIPTS so this cycle's remaining steps are post-split"
rsync -a "$NEW_SCRIPTS/" "$LEGACY_SCRIPTS/"
find "$LEGACY_SCRIPTS" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Note on overwriting a running script: ensure-template-sync.sh is executing
# from $LEGACY_SCRIPTS/self-check/ and we just replaced it. rsync writes a temp
# file and renames it into place, so the running bash keeps reading the inode it
# opened and finishes the OLD script to completion. That is already how every
# template sync has worked since the beginning; self-check.sh's `tolerate_missing`
# handling and its reconcile pass exist for precisely this window.
#
# The consequence to keep in mind: the rsync that runs a few lines below, in
# ensure-template-sync.sh, is still the OLD whole-root `--delete` sync honouring
# root/.ignore. That is why .ignore must keep every one of its entries for this
# release, plus /scripts/ — see the R2 block at the top of that file.

echo "Migration $MIGRATION_NAME completed successfully"
exit 0
