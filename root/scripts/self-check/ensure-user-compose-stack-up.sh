#!/bin/bash
set -e

COMPOSE_FILE="/DATA/AppData/casaos/apps/yundera/docker-compose.yml"
LOG_FILE="/DATA/AppData/casaos/apps/yundera/log/yundera.log"

touch "$LOG_FILE"  # Ensure the log file exists

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Use nohup to ensure the docker compose command survives any signal interruptions
# Redirect output to log file to capture everything
nohup docker compose -f "$COMPOSE_FILE" up --quiet-pull -d >> "$LOG_FILE" 2>&1 &
DOCKER_PID=$!

echo "Docker compose started with nohup (PID: $DOCKER_PID)"

# Check the exit code
if wait $DOCKER_PID 2>/dev/null; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

if [ $EXIT_CODE -eq 0 ]; then
    echo "User compose stack is up successfully"
else
    echo "ERROR: Failed to start docker containers (exit code: $EXIT_CODE)"
    exit $EXIT_CODE
fi