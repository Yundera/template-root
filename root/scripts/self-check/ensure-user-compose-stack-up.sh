#!/bin/bash
set -eo pipefail

COMPOSE_DIR="/DATA/AppData/casaos/apps/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
LOG_FILE="$COMPOSE_DIR/log/yundera.log"

touch "$LOG_FILE"  # Ensure the log file exists

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Run docker compose and capture output to both console and log file
if docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" up --quiet-pull -d 2>&1 | tee -a "$LOG_FILE"; then
    echo "User compose stack is up successfully"
else
    echo "ERROR: Failed to start docker containers"
    echo "--- Docker compose output (last 20 lines) ---"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    echo "--- End of docker compose output ---"
    exit 1
fi
