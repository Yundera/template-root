#!/bin/bash
# ensure-casadash-stack.sh - Deploy CasaDash behind its AppShield gate.
#
# CasaDash (github.com/worph/CasaDash) is the dashboard-only CasaOS replacement.
# Phase 1 runs it ALONGSIDE CasaOS: it lists and can manage every app, while CasaOS
# stays the only installer. See doc/casadash-migration.md.
#
# Deployed to /DATA/AppData/.casadash. The leading dot keeps the directory out of
# CasaDash's own managed-app scan of /DATA/AppData.
#
# SECURITY: CasaDash ships with no authentication whatsoever and mounts the Docker
# socket. The compose file never publishes its port — the AppShield gate in the same
# stack is the only way in. Do not "temporarily" add a ports: mapping to debug.
#
# ORDERING: must run AFTER ensure-user-compose-stack-up.sh — the `pcs` network is
# owned by the yundera stack and joined here as external, and the gate depends on
# auth-registrar / dex (yundera stack) and casaos-oidc-bridge (casaos stack) being
# reachable by name on that network.
set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

# The casadash container talks to the Docker socket as a non-root user, so it needs
# the socket's group. Resolve it from the host rather than assuming the usual 999.
if [ ! -S /var/run/docker.sock ]; then
    log_error "/var/run/docker.sock not found; cannot determine DOCKER_GID"
    exit 1
fi
DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"

# CasaDash stamps container timezones from TZ. The unified .env does not carry it.
if [ -f /etc/timezone ]; then
    TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"
elif [ -L /etc/localtime ]; then
    TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
else
    TZ="UTC"
fi

exec "$YND_ROOT/scripts/tools/deploy-stack.sh" casadash /DATA/AppData/.casadash \
    "DOCKER_GID=$DOCKER_GID" \
    "TZ=$TZ"
