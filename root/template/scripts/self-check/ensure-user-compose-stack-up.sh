#!/bin/bash
# Bring the yundera stack up: the admin app and its AppShield gate.
#
# Also prepares what that `up` interpolates and binds — ADMIN_ASSERTION_SECRET
# and the gate's session dir — so no ordering rule is needed: `pcs support`
# (pcs-orchestrator src/scripts/support.ts) runs this script on its own, by path.
#
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
source "$COMPOSE_DIR/template/scripts/library/secrets.sh"

# --- the admin gate's secret ---------------------------------------------------
# The dashboard (settings-center-app, container `admin-app`) sits behind an
# AppShield gate (container `admin`). Two things ride on ONE secret:
#
#   gate  -> app : X-AppShield-Assertion, a per-request HS256 JWT stating who the
#                  caller is. The app verifies it and refuses every request
#                  without one, rather than trusting Remote-User & co — because
#                  `admin-app` is reachable from every container on the `pcs`
#                  network, and this app can open a host shell.
#   app   -> gate: control tokens (aud=appshield-control) authorising session
#                  revocation, so deleting an account or resetting its password
#                  ends sessions already in flight.
#
# Both sides read it as IDENTITY_ASSERTION_SECRET; here it is ADMIN_ASSERTION_SECRET
# so the compose file names which pair it belongs to. docker compose interpolates
# it from the unified .env, and unset renders as empty — which fails CLOSED (the
# app authenticates nobody) rather than open, but is still a broken dashboard.
# Hence minted here, before the `up` below.
#
# Rotating the secret is safe at any time — it invalidates in-flight assertions
# (they live ~60s) and every gate session's usefulness, i.e. it costs one round of
# re-logins. RECOVERY: nothing to back up; a lost secret is re-minted here.
ensure_secret ADMIN_ASSERTION_SECRET openssl rand -hex 32

# The gate persists its sessions here (sessions.json), so the directory exists
# before the stack comes up — beside the app's own /app/data bind, and inside
# backups of /DATA/AppData/yundera.
#
# AND IT IS CHOWNED, which is the part that is not cosmetic. The gate container
# runs as 65534 (pinned in docker-compose.yml next to the bind) and saves through
# a temp file in this directory, so it needs the DIRECTORY writable. Whoever
# created it first — Docker as root, or a self-check invoked from the admin
# container as uid 1000 — decided that, and got it wrong on wisera: every login
# logged "[session] save failed: permission denied" and the gate's 720h session
# TTL was fiction, because a gate that cannot persist sessions loses them all on
# every restart. The dashboard is the one app where that is most visible: it
# fronts onboarding, and it is restarted by every compose action it performs.
#
# Recursive: it must also fix a sessions.json a previous, differently-owned run
# left behind. Non-fatal — a failed chown costs session persistence, not the
# dashboard.
GATE_UID=65534
mkdir -p "$COMPOSE_DIR/admin/gate-data"
chown -R "$GATE_UID:$GATE_UID" "$COMPOSE_DIR/admin/gate-data" 2>/dev/null \
    || log_warn "Could not chown admin/gate-data to $GATE_UID; the gate will not persist sessions"

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
