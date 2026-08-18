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
# nobody) rather than open, but is still a broken dashboard.
#
# Generate-once, like AUTHELIA_DEX_SECRET in ensure-authelia.sh: the plaintext
# lives in .pcs.secret.env and is mirrored into the unified .env for compose.
# Rotating it is safe at any time — it invalidates in-flight assertions (they live
# ~60s) and every gate session's usefulness, i.e. it costs one round of re-logins.
#
# RECOVERY: nothing to back up. If the secret is lost, this script mints a new one
# on the next run and both containers pick it up when the stack is recreated.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
STACK_UP="$YND_ROOT/scripts/self-check/ensure-user-compose-stack-up.sh"

MINTED=0
ADMIN_ASSERTION_SECRET="$("$ENV_MGR" get ADMIN_ASSERTION_SECRET "$SECRET_ENV")"
if [ -z "$ADMIN_ASSERTION_SECRET" ]; then
    ADMIN_ASSERTION_SECRET="$(openssl rand -hex 32)"
    "$ENV_MGR" set ADMIN_ASSERTION_SECRET "$ADMIN_ASSERTION_SECRET" "$SECRET_ENV"
    MINTED=1
    log_info "Generated ADMIN_ASSERTION_SECRET (admin gate <-> admin app)"
fi

# Mirrored on every run, not just on creation: ensure-env-vars-valid.sh rebuilds
# the unified .env from its sources, and a secret minted after that rebuild would
# otherwise be missing from the file compose actually reads.
PREVIOUS_IN_UNIFIED="$("$ENV_MGR" get ADMIN_ASSERTION_SECRET "$UNIFIED_ENV")"
"$ENV_MGR" set ADMIN_ASSERTION_SECRET "$ADMIN_ASSERTION_SECRET" "$UNIFIED_ENV"

# THE FIRST CYCLE ON AN EXISTING BOX IS THE CASE THIS HANDLES.
#
# self-check.sh runs scripts in the order of scripts-config.txt, but a script
# that APPEARS during a run (ensure-template-sync.sh rsyncs the new config, then
# the second pass picks up unknown entries) runs after every pre-existing one —
# including ensure-user-compose-stack-up.sh. So on the very cycle that first
# delivers the gate, the stack has already been brought up with
# ${ADMIN_ASSERTION_SECRET} interpolating to an empty string: the gate signs no
# assertion, the app verifies none, and the dashboard authenticates NOBODY until
# something recreates those containers. It fails closed, which is the right
# direction, but it would stay broken until the next nightly self-check.
#
# So bring the stack up again ourselves when the value compose was started with
# is not the value now on disk. `up -d` is idempotent and only recreates
# containers whose config actually changed, so this is a no-op on every
# subsequent run — the same shape ensure-yundera-login.sh uses to re-run
# ensure-dex.sh after changing a Dex drop-in.
#
# Tolerant on purpose: ensure-user-compose-stack-up.sh runs on its own next cycle
# anyway, so a failure here is a delay, not a dead end.
if [ "$MINTED" = "1" ] || [ "$PREVIOUS_IN_UNIFIED" != "$ADMIN_ASSERTION_SECRET" ]; then
    if [ -x "$STACK_UP" ] || [ -f "$STACK_UP" ]; then
        log_info "Admin gate secret changed - recreating the stack so both sides pick it up"
        bash "$STACK_UP" || log_warn "ensure-user-compose-stack-up.sh failed while applying the admin gate secret"
    fi
fi

# The gate persists its sessions here. Docker would create it as root on first
# up, which is fine — this is only so the directory exists next to the app's own
# /app/data bind and shows up in backups of /DATA/AppData/yundera.
mkdir -p /DATA/AppData/yundera/admin/gate-data

log_success "Admin gate secret is in place"
