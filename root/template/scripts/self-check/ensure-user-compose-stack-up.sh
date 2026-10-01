#!/bin/bash
# `docker compose up -d` re-pulls any image not already in the local cache,
# so the same Contabo↔GHCR resets that hit ensure-user-compose-pulled.sh hit
# here too. Retry with exponential backoff for the same reason. `up -d` is
# idempotent: containers already at the desired state are left alone.
set -eo pipefail

COMPOSE_DIR="/DATA/AppData/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
LOG_FILE="$COMPOSE_DIR/log/yundera.log"

MAX_ATTEMPTS=5
INITIAL_BACKOFF=15
MAX_BACKOFF=120

touch "$LOG_FILE"  # Ensure the log file exists

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

# The yundera stack is the admin app alone; routing, login and the dashboard are
# the stock mesh template's stacks (ensure-mesh-installed.sh).
source "$COMPOSE_DIR/template/scripts/library/log.sh"
source "$COMPOSE_DIR/template/scripts/library/stacks.sh"

# `pcs` is external here and created by nobody's compose — normally the mesh
# stack's deploy has made it by now, but this must not depend on that.
ensure_pcs_network || echo "WARN: could not create the pcs network; up will say why"

ORPHANS_FLAG="--remove-orphans"

backoff="$INITIAL_BACKOFF"
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" up --quiet-pull $ORPHANS_FLAG -d 2>&1 | tee -a "$LOG_FILE"; then
        echo "User compose stack is up successfully (attempt $attempt/$MAX_ATTEMPTS)"
        exit 0
    fi

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "WARN: stack-up attempt $attempt/$MAX_ATTEMPTS failed, retrying in ${backoff}s..."
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
    fi
    attempt=$((attempt + 1))
done

echo "ERROR: Failed to start docker containers after $MAX_ATTEMPTS attempts"
echo "--- Docker compose output (last 20 lines) ---"
tail -20 "$LOG_FILE" 2>/dev/null || true
echo "--- End of docker compose output ---"
exit 1
