#!/bin/bash
set -eo pipefail

COMPOSE_DIR="/DATA/AppData/casaos/apps/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
LOG_FILE="$COMPOSE_DIR/log/yundera.log"

sync

# Stop any existing containers (with error suppression)
docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

# Start containers and capture output
# Use --force-recreate to handle orphaned containers from failed previous attempts
if docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" up --quiet-pull --force-recreate -d 2>&1 | tee -a "$LOG_FILE"; then
    echo "User compose stack is up"
else
    echo "ERROR: Failed to start docker containers"
    echo "--- Docker compose output (last 20 lines) ---"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    echo "--- End of docker compose output ---"
    exit 1
fi
