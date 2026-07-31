#!/bin/bash

# Sweep the leftovers of the CasaOS OIDC path.
#
# Dex's `casaos` connector and the casaos-oidc-bridge service were removed from
# the template (dex.config.yaml.tmpl, stacks/casaos/docker-compose.yml): Authelia
# is the PCS-local credential store now, so federating a second local identity
# through CasaOS bought nothing, and the bridge would have died with CasaOS in
# phase 3 anyway. See doc/maison-migration.md.
#
# What this removes on an already-deployed host:
#   - BRIDGE_SECRET from .pcs.secret.env and the unified .env (the Dex<->bridge
#     connector secret; nothing reads it after this template push),
#   - /DATA/AppData/yundera/casaos-oidc-bridge/ (the bridge's ES256 signing key).
#
# The running container itself is NOT this script's job: ensure-casaos-stack.sh
# ups the `casaos` project through deploy-stack.sh with --remove-orphans later in
# the same self-check cycle, which tears it down.
#
# Best-effort throughout. A migration failure aborts template sync, and none of
# this is worth blocking an update over — worst case a stale secret and an unused
# directory survive to the next cycle.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
SECRET_ENV="$YND_ROOT/.pcs.secret.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MANAGER="$YND_ROOT/scripts/tools/env-file-manager.sh"
BRIDGE_DATA="/DATA/AppData/yundera/casaos-oidc-bridge"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

if [ -x "$ENV_MANAGER" ]; then
    for f in "$SECRET_ENV" "$UNIFIED_ENV"; do
        if [ -f "$f" ] && "$ENV_MANAGER" exists BRIDGE_SECRET "$f" >/dev/null 2>&1; then
            if "$ENV_MANAGER" delete BRIDGE_SECRET "$f" >/dev/null 2>&1; then
                echo "Removed BRIDGE_SECRET from $f"
            else
                echo "Warning: could not remove BRIDGE_SECRET from $f, leaving it in place"
            fi
        fi
    done
else
    echo "Warning: $ENV_MANAGER not executable, leaving BRIDGE_SECRET in place"
fi

if [ -d "$BRIDGE_DATA" ]; then
    if rm -rf "$BRIDGE_DATA"; then
        echo "Removed bridge data dir $BRIDGE_DATA"
    else
        echo "Warning: could not remove $BRIDGE_DATA, leaving it in place"
    fi
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
