#!/bin/bash
set -eo pipefail

COMPOSE_DIR="/DATA/AppData/yundera"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
LOG_FILE="$COMPOSE_DIR/log/yundera.log"

source "$COMPOSE_DIR/template/scripts/library/log.sh"
source "$COMPOSE_DIR/template/scripts/library/stacks.sh"

sync

# The yundera stack is the admin app alone since the mesh/auth split, so this
# restarts the admin app — routing and login (mesh, auth) stay up throughout.
#
# Without --remove-orphans while a handover to mesh/auth is pending: `down` with
# it would take the box's routing and login down with the admin app, and `up`
# would never bring them back. See yundera_handover_pending.
yundera_orphans_flag
ensure_pcs_network || echo "WARN: could not create the pcs network; up will say why"

# Stop any existing containers (with error suppression)
docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" down $ORPHANS_FLAG 2>/dev/null || true

# Start containers and capture output
if docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_FILE" up --quiet-pull $ORPHANS_FLAG -d 2>&1 | tee -a "$LOG_FILE"; then
    echo "User compose stack is up"
else
    echo "ERROR: Failed to start docker containers"
    echo "--- Docker compose output (last 20 lines) ---"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    echo "--- End of docker compose output ---"
    exit 1
fi
