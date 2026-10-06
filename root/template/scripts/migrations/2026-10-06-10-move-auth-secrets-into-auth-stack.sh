#!/bin/bash
# Migration: carry the Dex<->Authelia secrets from .pcs.secret.env into the auth stack .stack.env

# Before the switch to the stock mesh template, this template minted the auth
# stack's two secrets on the box and kept them in the hand-off file:
#
#   AUTHELIA_DEX_SECRET   Dex's client secret at Authelia (Authelia stores its hash
#                         in auth/authelia/secrets/dex-client-hash)
#   DEX_SESSION_KEY       Dex's session-cookie encryption key
#
# The mesh template keeps them in /DATA/AppData/auth/.stack.env and mints them
# when they are absent there. A box crossing from stable reaches the mesh install
# with them still in .pcs.secret.env, so the mesh would mint new ones: Authelia's
# stored hash no longer matches Dex's secret (Local Account login fails with
# invalid_client) and every Dex session is dropped. This carries the existing
# values over first. Migrations run inside ensure-template-sync.sh, ahead of
# ensure-mesh-installed.sh, and this one sorts after
# 2026-10-01-10-move-state-into-stack-folders.sh, which has already moved
# auth/authelia - with the hash that matches these values - into place.
#
# A MIGRATION, NOT AN ENSURE STEP: only a box that ran the pre-switch template has
# these keys in .pcs.secret.env; a fresh box never does. A frozen/local box runs
# no migrations and keeps them where they are until it follows a channel again.
#
# Per key:
#   absent or empty in .pcs.secret.env   nothing to do
#   absent in .stack.env                 copied, read back, then deleted from
#                                        .pcs.secret.env
#   present in .stack.env                .stack.env wins (the box already
#                                        switched); deleted from .pcs.secret.env
# .pcs.secret.env is copied whole to .pcs.secret.env.<date>.old (600) before it is
# first modified, as library/env.sh's stack_env_adopt does.
#
# A HARD FAILURE when a value does not read back: a non-zero exit aborts the sync,
# which keeps the box on its old tree. Exiting 0 would let the mesh mint new
# secrets - the bug this exists to prevent.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
# The downloaded tree's own tool: the installed one may still be the old tree's.
ENV_MGR="$(cd "$(dirname "$0")/.." && pwd)/tools/env-file-manager.sh"

LEGACY="/DATA/AppData/yundera/.pcs.secret.env"
TARGET="/DATA/AppData/auth/.stack.env"
MESH_ENV="/DATA/AppData/mesh/.env"
KEYS="AUTHELIA_DEX_SECRET DEX_SESSION_KEY"

echo "Starting migration: $MIGRATION_NAME"

if [ ! -f "$LEGACY" ]; then
    echo "No $LEGACY - nothing to carry over"
    exit 0
fi

# Owned like the mesh template's own .stack.env files (stack_env_set in its
# library/common.sh): PUID:PGID from the mesh .env, 1000 by default.
mesh_env_get() {
    local v=""
    [ -f "$MESH_ENV" ] && v="$("$ENV_MGR" get "$1" "$MESH_ENV")"
    echo "${v:-1000}"
}

snapshot=""
for key in $KEYS; do
    value="$("$ENV_MGR" get "$key" "$LEGACY")"
    if [ -z "$value" ]; then
        "$ENV_MGR" exists "$key" "$LEGACY" 2>/dev/null || continue
    fi

    if [ -z "$snapshot" ]; then
        snapshot="$LEGACY.$(date +%F).old"
        if [ ! -e "$snapshot" ]; then
            cp -p "$LEGACY" "$snapshot"
            chmod 600 "$snapshot"
            echo "Saved $(basename "$LEGACY") as $(basename "$snapshot")"
        fi
    fi

    current="$("$ENV_MGR" get "$key" "$TARGET")"
    if [ -n "$current" ]; then
        [ "$current" = "$value" ] || echo "Warning: $key differs between $(basename "$LEGACY") and $TARGET - keeping $TARGET's"
    elif [ -n "$value" ]; then
        if [ ! -f "$TARGET" ]; then
            mkdir -p "$(dirname "$TARGET")"
            install -m 600 -o "$(mesh_env_get PUID)" -g "$(mesh_env_get PGID)" /dev/null "$TARGET"
        fi
        "$ENV_MGR" set "$key" "$value" "$TARGET" >/dev/null
        if [ "$("$ENV_MGR" get "$key" "$TARGET")" != "$value" ]; then
            echo "Error: $key did not read back from $TARGET - leaving it in $(basename "$LEGACY")"
            exit 1
        fi
        echo "Moved $key from $(basename "$LEGACY") to $TARGET"
    fi
    "$ENV_MGR" delete "$key" "$LEGACY" >/dev/null
done

echo "Migration $MIGRATION_NAME completed successfully"
