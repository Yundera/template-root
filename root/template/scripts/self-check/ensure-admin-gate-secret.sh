#!/bin/bash
# ensure-admin-gate-secret.sh - Mint the shared secret between the admin gate and
# the admin app.
#
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
# so the compose file names which pair it belongs to.
#
# MUST RUN BEFORE the yundera stack comes up (ensure-user-compose-stack-up.sh):
# docker compose interpolates ${ADMIN_ASSERTION_SECRET} from the unified .env, and
# an unset variable renders as empty — which fails CLOSED (the app authenticates
# nobody) rather than open, but is still a broken dashboard. scripts-config.txt
# orders it, and self-check.sh re-runs the whole list when a sync changes it, so
# that order holds even on the cycle that first delivers this script.
#
# Rotating the secret is safe at any time — it invalidates in-flight assertions
# (they live ~60s) and every gate session's usefulness, i.e. it costs one round of
# re-logins.
#
# RECOVERY: nothing to back up. If the secret is lost, this script mints a new one
# on the next run and both containers pick it up when the stack is recreated.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/secrets.sh"

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
mkdir -p "$YND_ROOT/admin/gate-data"
chown -R "$GATE_UID:$GATE_UID" "$YND_ROOT/admin/gate-data" 2>/dev/null \
    || log_warn "Could not chown admin/gate-data to $GATE_UID; the gate will not persist sessions"

log_success "Admin gate secret is in place"
