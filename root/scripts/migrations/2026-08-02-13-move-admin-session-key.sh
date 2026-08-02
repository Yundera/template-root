#!/bin/bash

# Move the admin app's session-signing key out of the template tree.
#
# settings-center-app persists the HMAC key that signs the admin session cookie
# and the OIDC state cookie at /app/data/admin-session-key, so that restarting
# the container does not sign every user out. /app/data used to be a bind of the
# whole stack directory (/DATA/AppData/casaos/apps/yundera) — which is also the
# rsync target of ensure-template-sync.sh:
#
#     rsync -a --delete --exclude-from=<template>/.ignore <template>/ $YND_ROOT/
#
# admin-session-key is not in .ignore and does not exist in the template, so
# --delete removed it on every single template update; the next container start
# minted a fresh key and invalidated every session. The env files survived only
# because they ARE listed in .ignore.
#
# The compose file now binds /DATA/AppData/yundera/admin (beside dex/ and auth/,
# outside the synced tree) instead. This migration carries an existing key across
# so the upgrade itself doesn't sign anyone out — it runs from the newly
# downloaded tree BEFORE the rsync, i.e. while the old key is still on disk.
#
# Best-effort: if the move fails, the app mints a new key on next start. That
# costs one round of re-logins, which is not worth aborting a template sync over.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

OLD_KEY="/DATA/AppData/casaos/apps/yundera/admin-session-key"
NEW_DIR="/DATA/AppData/yundera/admin"
NEW_KEY="$NEW_DIR/admin-session-key"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

if mkdir -p "$NEW_DIR" 2>/dev/null; then
    chmod 700 "$NEW_DIR" 2>/dev/null || true
else
    echo "Warning: could not create $NEW_DIR; docker will create it on next up"
fi

if [ -f "$NEW_KEY" ]; then
    # Already in place (e.g. the container came up on the new mount before this
    # ran). The old copy is now dead weight in a tree that rsync will prune anyway.
    echo "Key already present at $NEW_KEY, leaving it alone"
    rm -f "$OLD_KEY" 2>/dev/null || true
elif [ -f "$OLD_KEY" ]; then
    if mv "$OLD_KEY" "$NEW_KEY" 2>/dev/null; then
        chmod 600 "$NEW_KEY" 2>/dev/null || true
        echo "Moved admin session key to $NEW_KEY (sessions preserved)"
    else
        echo "Warning: could not move $OLD_KEY; the app will mint a new key (users re-login once)"
    fi
else
    echo "No existing admin session key found; the app will create one at $NEW_KEY"
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
