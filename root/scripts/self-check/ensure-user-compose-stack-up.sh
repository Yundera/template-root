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

# Wait for Docker to be fully ready after previous operations (pull, etc.)
# This prevents race conditions with containerd/overlay filesystem
echo "Waiting for Docker to stabilize..."
for i in {1..10}; do
    if docker info > /dev/null 2>&1 && docker network ls > /dev/null 2>&1; then
        break
    fi
    sleep 1
done
sync  # Flush filesystem buffers

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
