#!/bin/bash

# Remove CasaOS (Maison migration, phase 3).
#
# The `casaos` stack and ensure-casaos-stack.sh are deleted from the template.
# Nothing re-creates the container, but nothing tears down the existing one
# either — the yundera stack's `--remove-orphans` only prunes the *yundera*
# project, and `casaos` is its own compose project. So this migration stops it,
# and repoints the root domain at Maison before it goes.
#
# ORDER MATTERS: repoint routing FIRST, stop CasaOS SECOND. The reverse leaves
# ${DOMAIN} 502-ing for the rest of the self-check cycle.
#
# ############################################################################
# # /DATA/AppData/casaos IS NOT CASAOS'S TO DELETE.                          #
# # It is CasaOS's AppData root, and it contains apps/ — including           #
# # apps/yundera, which is the template itself ($YND_ROOT, the directory this #
# # script is running from). Removing the stack means removing the           #
# # CONTAINER plus the stack's own docker-compose.yml/.env, never the tree.   #
# ############################################################################
#
# App compose files stay under /DATA/AppData/casaos/apps/<app> and keep being
# projected into /DATA/AppData/<app> by ensure-maison-app-mirror.sh, which is
# why that script survives phase 3's outline for now. Running app containers are
# untouched: compose derives the project name from the directory basename, so
# the mirrored copies address the very same projects Maison already manages.
#
# Best-effort: a failure here must not abort template sync. The worst case is a
# CasaOS container that lingers until the next cycle.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV="$YND_ROOT/.pcs.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MANAGER="$YND_ROOT/scripts/tools/env-file-manager.sh"
STACK_DIR="/DATA/AppData/casaos"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Root-domain routing: casaos:8080 -> maison:80
#
# Only rewrite values that still point at CasaOS. An operator who deliberately
# set the root domain to some other service keeps their choice.
# ---------------------------------------------------------------------------
if [ -x "$ENV_MANAGER" ] && [ -f "$PCS_ENV" ]; then
    current_host="$("$ENV_MANAGER" get DEFAULT_SERVICE_HOST "$PCS_ENV" 2>/dev/null || true)"
    if [ -z "$current_host" ] || [ "$current_host" = "casaos" ]; then
        "$ENV_MANAGER" set DEFAULT_SERVICE_HOST "maison" "$PCS_ENV" || true
        "$ENV_MANAGER" set DEFAULT_SERVICE_PORT "80" "$PCS_ENV" || true
        # Keep the unified .env in step so mesh-router-caddy picks it up on this
        # cycle rather than the next one (ensure-env-vars-valid.sh regenerates it
        # anyway, but that already ran earlier in the self-check).
        if [ -f "$UNIFIED_ENV" ]; then
            "$ENV_MANAGER" set DEFAULT_SERVICE_HOST "maison" "$UNIFIED_ENV" || true
            "$ENV_MANAGER" set DEFAULT_SERVICE_PORT "80" "$UNIFIED_ENV" || true
        fi
        echo "Root domain repointed to the Maison gate (maison:80)"
    else
        echo "DEFAULT_SERVICE_HOST is '$current_host' (not casaos) — leaving routing alone"
    fi
else
    echo "Warning: cannot reach $ENV_MANAGER/$PCS_ENV; root domain still points at CasaOS"
fi

# ---------------------------------------------------------------------------
# 2. Tear down the casaos compose project.
#
# `down` on the stack file removes the container and its default network but
# touches nothing under apps/. No -v: any named volume it declared would take
# data with it. If the compose file is already gone, fall back to removing the
# container by name.
# ---------------------------------------------------------------------------
if [ -f "$STACK_DIR/docker-compose.yml" ]; then
    if docker compose -f "$STACK_DIR/docker-compose.yml" --project-directory "$STACK_DIR" down 2>/dev/null; then
        echo "Stopped and removed the casaos stack"
    else
        echo "Warning: 'docker compose down' failed for $STACK_DIR; falling back to container removal"
        docker rm -f casaos >/dev/null 2>&1 || true
    fi
    # The stack's own files only — NOT the directory (see the banner above).
    rm -f "$STACK_DIR/docker-compose.yml" "$STACK_DIR/.env"
    echo "Removed the casaos stack files from $STACK_DIR (apps/ untouched)"
elif docker inspect casaos >/dev/null 2>&1; then
    docker rm -f casaos >/dev/null 2>&1 || true
    echo "Removed the leftover casaos container (no stack file found)"
else
    echo "No casaos stack or container found; nothing to tear down"
fi

# Sanity: the tree this script lives in must have survived. Loud, but do not
# fail the sync — if it were gone, template sync would already be doomed.
if [ ! -d "$YND_ROOT" ]; then
    echo "ERROR: $YND_ROOT is missing after CasaOS removal — this should be impossible"
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
