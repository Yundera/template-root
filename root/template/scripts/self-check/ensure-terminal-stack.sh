#!/bin/bash
# ensure-terminal-stack.sh - Deploy the web Terminal as a system app.
#
# The stack is the Yundera AppStore's Terminal app, copied into stacks/terminal/ (see the
# header there). The app configures itself — its SSH key and authorized_keys line are
# set up by the container at start (TERMINAL_SETUP) — so this script only does what the
# store install would: supply the deployment's variables and bring it up.
#
# The store compose reads the variables Maison gives every app (APP_DOMAIN,
# APP_PUBLIC_IP_DASH, APP_NET, and `domain`), which the unified .env does not carry, so
# they are passed to deploy-stack.sh here.
#
# Deployed to /DATA/AppData/terminal — the same directory and compose project the store
# app installs into, so a box that already installed it from the store is adopted in
# place rather than ending up with two.
#
# Opt out with TERMINAL_ENABLED=false (or 0/no/off) in .pcs.env: the stack is taken down
# and not redeployed. Default is enabled.
#
# ORDERING: must run AFTER ensure-mesh-stack.sh and ensure-auth-stack.sh — the gate
# joins the shared `pcs` network and reaches auth-registrar (auth stack) on it.
set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"

PCS_ENV="$YND_ROOT/.pcs.env"
UNIFIED_ENV="$YND_ROOT/.env"
STACK_DIR="/DATA/AppData/terminal"

env_get() {
    "$YND_TEMPLATE/scripts/tools/env-file-manager.sh" get "$1" "$2" 2>/dev/null || true
}

ENABLED="$(env_get TERMINAL_ENABLED "$PCS_ENV")"
case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
        if [ -f "$STACK_DIR/docker-compose.yml" ] && docker compose version >/dev/null 2>&1; then
            log_info "Terminal disabled by TERMINAL_ENABLED in .pcs.env - taking the terminal stack down"
            docker compose --project-directory "$STACK_DIR" \
                -f "$STACK_DIR/docker-compose.yml" down --remove-orphans \
                || log_warn "Terminal stack teardown failed; continuing"
        fi
        exit 0
        ;;
esac

DOMAIN="$(env_get DOMAIN "$UNIFIED_ENV")"

exec "$YND_TEMPLATE/scripts/tools/deploy-stack.sh" terminal "$STACK_DIR" \
    "APP_NET=pcs" \
    "APP_DOMAIN=$DOMAIN" \
    "domain=$DOMAIN" \
    "APP_PUBLIC_IP_DASH=$(env_get PUBLIC_IP_DASH "$UNIFIED_ENV")"
