#!/bin/bash

# Sweep JWT_SECRET, and repair the unified .env's permissions.
#
# JWT_SECRET was minted per-PCS by ensure-env-vars-valid.sh as the HMAC for the
# settings-center-app's OIDC state cookie. The app stopped reading it: both the
# state cookie and the admin session cookie are signed with the key it persists
# itself at /app/data/admin-session-key (src/backend/auth/sessionKey.ts), so that
# a container restart no longer invalidates every session. Nothing else on the
# PCS consumes JWT_SECRET, so it is dead weight in a secret file.
#
# The permissions half: the unified .env concatenates .pcs.secret.env verbatim,
# but ensure-env-vars-valid.sh wrote it with a plain `>` redirect, which keeps
# whatever mode the file already had. Hosts provisioned before this carry it at
# 755 — world-readable, while its three sources and every derived copy
# (tools/deploy-stack.sh) are 600. The ensure script now creates it 600, but that
# only fixes it on the next self-check tick; do it here so the window closes with
# the template push that introduces the fix.
#
# Best-effort throughout. A migration failure aborts template sync, and neither
# of these is worth blocking an update over — the ensure script re-asserts the
# mode on every subsequent run anyway.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
SECRET_ENV="$YND_ROOT/.pcs.secret.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MANAGER="$YND_ROOT/scripts/tools/env-file-manager.sh"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

# Tighten the unified .env before touching its contents — if anything below
# fails, the perms fix has already landed.
if [ -f "$UNIFIED_ENV" ]; then
    if chmod 600 "$UNIFIED_ENV" 2>/dev/null; then
        echo "Set 600 on $UNIFIED_ENV"
    else
        echo "Warning: could not chmod $UNIFIED_ENV, leaving its mode as-is"
    fi
fi

if [ -x "$ENV_MANAGER" ]; then
    for f in "$SECRET_ENV" "$UNIFIED_ENV"; do
        if [ -f "$f" ] && "$ENV_MANAGER" exists JWT_SECRET "$f" >/dev/null 2>&1; then
            if "$ENV_MANAGER" delete JWT_SECRET "$f" >/dev/null 2>&1; then
                echo "Removed JWT_SECRET from $f"
            else
                echo "Warning: could not remove JWT_SECRET from $f, leaving it in place"
            fi
        fi
    done
else
    echo "Warning: $ENV_MANAGER not executable, leaving JWT_SECRET in place"
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
