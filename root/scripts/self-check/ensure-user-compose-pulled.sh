#!/bin/bash
# Script to ensure Docker Compose images are pulled.
#
# Retries on transient failures: Contabo↔GHCR connectivity over IPv6 resets
# intermittently ("read: connection reset by peer" mid-pull), and a single
# failure here blocks the whole bootstrap. 5 attempts with backoff turns
# most resets into a slowdown rather than a fatal create.
set -e

COMPOSE_DIR="/DATA/AppData/casaos/apps/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

MAX_ATTEMPTS=5
BACKOFF_SECONDS=30

# Check if compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" pull --quiet; then
        echo "User compose stack pulled successfully (attempt $attempt/$MAX_ATTEMPTS)"
        exit 0
    fi

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "WARN: pull attempt $attempt/$MAX_ATTEMPTS failed, retrying in ${BACKOFF_SECONDS}s..."
        sleep "$BACKOFF_SECONDS"
    fi
    attempt=$((attempt + 1))
done

echo "ERROR: Failed to pull user compose stack after $MAX_ATTEMPTS attempts"
exit 1
