#!/bin/bash
# Script to ensure Docker Compose images are pulled.
#
# Primary defense against GHCR flakiness is ensure-outbound-ip-family.sh,
# which forces IPv4 resolution so pulls hit Fastly instead of GHCR's
# Azure-backed IPv6 edge. Retries here remain as defense-in-depth: a single
# transient failure shouldn't block bootstrap, and exponential backoff turns
# any residual reset into a slowdown rather than a fatal create.
#
# `pull` is idempotent: layers already on disk are skipped, so each retry only
# re-fetches whatever failed last time. Serialise with COMPOSE_PARALLEL_LIMIT=1
# so a single reset doesn't poison N concurrent streams at once.
set -e

COMPOSE_DIR="/DATA/AppData/casaos/apps/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

MAX_ATTEMPTS=10
INITIAL_BACKOFF=15
MAX_BACKOFF=300

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

backoff="$INITIAL_BACKOFF"
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if COMPOSE_PARALLEL_LIMIT=1 docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" pull; then
        echo "User compose stack pulled successfully (attempt $attempt/$MAX_ATTEMPTS)"
        exit 0
    fi

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "WARN: pull attempt $attempt/$MAX_ATTEMPTS failed, retrying in ${backoff}s..."
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
    fi
    attempt=$((attempt + 1))
done

echo "ERROR: Failed to pull user compose stack after $MAX_ATTEMPTS attempts"
exit 1
