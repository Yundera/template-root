#!/bin/bash

set -e  # Exit on any error

COMPOSE_FILE="/DATA/AppData/casaos/apps/yundera/docker-compose.yml"

sync

# Stop any existing containers (with error suppression)
docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true

# Start containers
if docker compose -f "$COMPOSE_FILE" up --quiet-pull -d; then
    echo "User compose stack is up"
else
    echo "ERROR: Failed to start docker containers"
    exit 1
fi