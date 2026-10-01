#!/bin/bash
# Migration: move the mesh and auth stacks' state out of the yundera root into the stacks' own folders

# Each platform stack owns the folder named after it (doc/stack-split.md). The
# mesh and auth stacks were split out of the yundera stack on 2026-09-30 but left
# their state behind in the yundera root. This moves it:
#
#   /DATA/AppData/yundera/data  ->  /DATA/AppData/mesh/data       certs/, ca/, caddy/
#   /DATA/AppData/yundera/auth  ->  /DATA/AppData/auth/authelia   users_database.yml, db.sqlite, secrets/, oidc/
#   /DATA/AppData/yundera/dex   ->  /DATA/AppData/auth/dex        dex.db, config.yaml, connectors.d/, frontend/
#
# THE MOVE IS A RENAME, AND THAT IS WHAT MAKES IT SAFE ON A LIVE BOX. Both sides
# are on one filesystem, so `mv` changes a name and nothing else: a container
# still bound to the old path keeps the same directory, because a bind mount
# holds the inode, not the path. Nothing is stopped here. The stack deploys later
# in this same self-check (ensure-mesh-stack.sh, ensure-auth-stack.sh) recreate
# the containers from the compose files this sync is about to deliver, which bind
# the new paths - the same directories again.
#
# What an old-bound container must NOT do in between is start again: Docker
# recreates a missing bind source as an empty directory, so the service would
# come up on nothing. The config-reload restarts in ensure-authelia.sh and
# ensure-dex.sh sit exactly in that window, which is what restart_if_bound
# (library/stacks.sh) is for.
#
# A HARD FAILURE ON PURPOSE, unlike most migrations here. A non-zero exit aborts
# the template sync, so the box keeps its old tree and its old compose files, all
# of which still agree with where the state is. Exiting 0 without having moved
# would be the dangerous outcome: the runner would write the marker, the new
# compose files would land, and the stacks would come up on empty folders - an
# unclaimed box on a fresh certificate.
#
# NOT COPIED INTO THE PRE-SUBTREE SHIM (root/scripts/migrations/). A box still on
# that layout would not run this on the cycle it crosses over, while the scripts
# it gets in that same cycle already bind the new paths. Left out deliberately:
# the whole fleet has crossed over (confirmed 2026-10-01).
#
# ROLLING BACK to a template that predates this: move the three directories back
# first - doc/stack-split.md, "Rolling the state move back".

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
YND_ROOT="/DATA/AppData/yundera"

echo "Starting migration: $MIGRATION_NAME"

# True when <dir> holds at least one file or symlink, at any depth. A tree of
# empty directories - what a `mkdir -p` or Docker's handling of a missing bind
# source leaves behind - counts as nothing.
has_files() {
    [ -n "$(find "$1" -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null)" ]
}

# ALL THREE OR NONE. A sync aborted after one rename would leave the old tree's
# compose files bound to a directory that has gone, so every pair is checked
# before anything is touched.
#
#   old missing                   nothing to do (already moved, or never there)
#   new missing or holds nothing  rename
#   old holds nothing             an empty leftover - removed
#   both hold files               refuse: which one is the box's state is not
#                                 something to guess at
PAIRS=(
    "$YND_ROOT/data|/DATA/AppData/mesh/data"
    "$YND_ROOT/auth|/DATA/AppData/auth/authelia"
    "$YND_ROOT/dex|/DATA/AppData/auth/dex"
)

# The nearest existing ancestor of <path>: where a `mkdir -p` would start.
existing_parent() {
    local p
    p="$(dirname "$1")"
    while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
    echo "$p"
}

for pair in "${PAIRS[@]}"; do
    old="${pair%%|*}"; new="${pair##*|}"
    [ -d "$old" ] && [ ! -L "$old" ] || continue
    has_files "$old" || continue
    if [ -e "$new" ] && has_files "$new"; then
        echo "Error: both $old and $new hold files - refusing to choose between them"
        exit 1
    fi
    # A rename only. Across filesystems `mv` degrades to copy-and-delete, which
    # would strand the running containers on a directory that no longer exists.
    if [ "$(stat -c %d "$old")" != "$(stat -c %d "$(existing_parent "$new")")" ]; then
        echo "Error: $old and $new are on different filesystems - not moving live state by copy"
        exit 1
    fi
done

for pair in "${PAIRS[@]}"; do
    old="${pair%%|*}"; new="${pair##*|}"
    if [ ! -d "$old" ] || [ -L "$old" ]; then
        echo "$old: not present, nothing to move"
        continue
    fi
    if ! has_files "$old"; then
        find "$old" -depth -type d -empty -delete
        echo "$old: empty leftover removed"
        continue
    fi
    # Only ever a tree of empty directories here - the check above refused
    # anything else.
    [ -e "$new" ] && find "$new" -depth -type d -empty -delete
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new"
    echo "Moved $old to $new"
done

echo "Migration $MIGRATION_NAME completed successfully"
