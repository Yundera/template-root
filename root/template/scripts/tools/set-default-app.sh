#!/bin/bash
# set-default-app.sh <host> <port> - point the root domain at another app.
#
# THE CONTRACT with mesh-console (and anything else that changes this setting):
# both templates ship this script at <template scripts>/tools/set-default-app.sh,
# with the same arguments and exit codes. The console only knows that path; where
# the setting is stored and what has to be recreated for it to take effect is
# this template's business, and lives here. mesh-router-template-root has its own
# copy for its own layout.
#
# What it does here: writes DEFAULT_SERVICE_HOST / DEFAULT_SERVICE_PORT into
# .pcs.env — the source; the unified .env and every stack's .env are generated
# from it, so a write anywhere else is undone by the next self-check — then
# re-runs the self-check steps that apply it:
#   ensure-env-vars-valid.sh  rebuild the unified .env from the sources
#   ensure-mesh-stack.sh      mesh-router-caddy: the root-domain routes + catch-all
#   ensure-auth-stack.sh      auth-registrar: ROOT_CLIENT_ID, so a login on the bare
#                             domain comes back to the bare domain
# Seconds, not a full self-check: no template sync, no apt, and `up` recreates only
# the services whose config changed (caddy, auth-registrar).
#
# Takes the self-check lock and REFUSES while a self-check runs rather than
# waiting for it: a self-check takes minutes, and it applies whatever .pcs.env
# holds when it reaches these steps anyway.
#
# Exit: 0 applied, 2 bad arguments, 75 a self-check is running (try later),
# 1 the setting was written but applying it failed (see yundera.log).
set -euo pipefail

HOST="${1:-}"
PORT="${2:-}"

# Same rules as the console validates with: a container name or a hostname such
# as host.docker.internal — Docker's own name charset, no shell metacharacters.
if ! [[ "$HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo "invalid host: '$HOST'" >&2
    exit 2
fi
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "invalid port: '$PORT'" >&2
    exit 2
fi

# The lock self-check.sh takes (and self-check-reboot.sh holds across its run).
exec 200>"/var/run/yundera-self-check.lock"
if ! flock -n 200; then
    echo "A self-check is running on this box - try again once it has finished." >&2
    exit 75
fi

YND_ROOT="/DATA/AppData/yundera"
SCRIPT_DIR="$YND_ROOT/template/scripts"
source "$SCRIPT_DIR/library/common.sh"

PCS_ENV="$YND_ROOT/.pcs.env"
"$SCRIPT_DIR/tools/env-file-manager.sh" set DEFAULT_SERVICE_HOST "$HOST" "$PCS_ENV"
"$SCRIPT_DIR/tools/env-file-manager.sh" set DEFAULT_SERVICE_PORT "$PORT" "$PCS_ENV"
log_info "Default app set to $HOST:$PORT - applying"

# Stop at the first failure: each step reads what the one before produced.
for step in ensure-env-vars-valid.sh ensure-mesh-stack.sh ensure-auth-stack.sh; do
    execute_script_with_logging "$SCRIPT_DIR/self-check/$step" || exit 1
done
