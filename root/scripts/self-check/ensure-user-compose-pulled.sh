#!/bin/bash
# Script to ensure Docker Compose images are pulled
set -e

COMPOSE_DIR="/DATA/AppData/casaos/apps/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

# Check if compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Pull images
if docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" pull --quiet; then
    echo "User compose stack pulled successfully"
else
    echo "ERROR: Failed to pull user compose stack"
    exit 1
fi
