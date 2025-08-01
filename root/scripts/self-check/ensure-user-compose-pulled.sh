#!/bin/bash
# Script to ensure Docker Compose services are running
set -e  # Exit on any error

COMPOSE_FILE="/DATA/AppData/casaos/apps/yundera/docker-compose.yml"

# Check if compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Start containers
if docker compose -f "$COMPOSE_FILE" pull --quiet; then
    echo "User compose stack pulled successfully"
else
    echo "ERROR: Failed to pull user compose stack"
    exit 1
fi