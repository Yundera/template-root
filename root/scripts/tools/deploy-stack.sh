#!/bin/bash
# deploy-stack.sh <stack-name> <dest-dir> [EXTRA_KEY=value ...]
#
# Deploys one of the auxiliary compose stacks shipped under
# /DATA/AppData/casaos/apps/yundera/stacks/<stack-name>/ (currently `casaos` and
# `casadash` — see doc/casadash-migration.md) to its own project directory:
#
#   1. copy stacks/<stack-name>/docker-compose.yml -> <dest-dir>/docker-compose.yml
#   2. generate <dest-dir>/.env from the yundera unified .env, plus any extra
#      KEY=value pairs given on the command line
#   3. docker compose pull, then up -d --remove-orphans (both with backoff)
#
# The unified .env is the ONLY source of environment truth: it is assembled by
# ensure-env-vars-valid.sh from .pcs.env + .pcs.secret.env + .ynd.user.env. Copying
# it wholesale (rather than cherry-picking keys) means a new variable added to any
# source file is automatically available to these stacks with no change here.
#
# The generated <dest-dir>/.env is chmod 600: it carries DEFAULT_PWD, PROVIDER_STR,
# USER_JWT and friends, exactly as the yundera .env does.
#
# Retries mirror ensure-user-compose-{pulled,stack-up}.sh: GHCR resets from Contabo
# are common enough that a single transient failure must not fail the self-check.
set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

STACK_NAME="${1:?usage: deploy-stack.sh <stack-name> <dest-dir> [KEY=value ...]}"
DEST_DIR="${2:?usage: deploy-stack.sh <stack-name> <dest-dir> [KEY=value ...]}"
shift 2

SRC_COMPOSE="$YND_ROOT/stacks/$STACK_NAME/docker-compose.yml"
UNIFIED_ENV="$YND_ROOT/.env"
DEST_COMPOSE="$DEST_DIR/docker-compose.yml"
DEST_ENV="$DEST_DIR/.env"

MAX_ATTEMPTS=5
INITIAL_BACKOFF=15
MAX_BACKOFF=120

if [ ! -f "$SRC_COMPOSE" ]; then
    log_error "Stack template not found: $SRC_COMPOSE"
    exit 1
fi
if [ ! -f "$UNIFIED_ENV" ]; then
    log_error "Unified .env not found: $UNIFIED_ENV (ensure-env-vars-valid.sh must run first)"
    exit 1
fi

mkdir -p "$DEST_DIR"

# --- 1. compose file -------------------------------------------------------
# Only write when the content actually differs, so an unchanged template does not
# churn the file's mtime on every self-check.
if ! cmp -s "$SRC_COMPOSE" "$DEST_COMPOSE"; then
    cp "$SRC_COMPOSE" "$DEST_COMPOSE"
    log_info "Updated $DEST_COMPOSE from template"
fi

# --- 2. .env ---------------------------------------------------------------
TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"
{
    echo "# AUTO-GENERATED FILE - DO NOT EDIT"
    echo "# Written by scripts/tools/deploy-stack.sh for the '$STACK_NAME' stack."
    echo "# Regenerated on every self-check; edit the sources instead:"
    echo "#   /DATA/AppData/casaos/apps/yundera/{.pcs.env,.pcs.secret.env,.ynd.user.env}"
    echo ""
    cat "$UNIFIED_ENV"
    if [ "$#" -gt 0 ]; then
        echo ""
        echo "# ============================================"
        echo "# Stack-specific values (resolved at deploy time)"
        echo "# ============================================"
        for kv in "$@"; do
            echo "$kv"
        done
    fi
} > "$TMP_ENV"

if ! cmp -s "$TMP_ENV" "$DEST_ENV"; then
    mv "$TMP_ENV" "$DEST_ENV"
    chmod 600 "$DEST_ENV"
    log_info "Regenerated $DEST_ENV"
else
    rm -f "$TMP_ENV"
fi

# --- 3. pull + up ----------------------------------------------------------
compose() {
    docker compose --project-directory "$DEST_DIR" -f "$DEST_COMPOSE" "$@"
}

run_with_backoff() {
    local what="$1"; shift
    local backoff="$INITIAL_BACKOFF"
    local attempt=1
    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            log_warn "[$STACK_NAME] $what attempt $attempt/$MAX_ATTEMPTS failed, retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$((backoff * 2))
            [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
        fi
        attempt=$((attempt + 1))
    done
    log_error "[$STACK_NAME] $what failed after $MAX_ATTEMPTS attempts"
    return 1
}

# Serialise layer streams — a single reset shouldn't poison N concurrent pulls.
pull_once() { COMPOSE_PARALLEL_LIMIT=1 compose pull; }
up_once()   { compose up --quiet-pull --remove-orphans -d; }

run_with_backoff "pull" pull_once
run_with_backoff "up" up_once

log_info "[$STACK_NAME] stack is up ($DEST_DIR)"
