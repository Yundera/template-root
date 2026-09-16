#!/bin/bash
# secrets.sh - generate-once secrets, persisted and mirrored.
#
#   ensure_secret ADMIN_ASSERTION_SECRET openssl rand -hex 32
#
# Reads NAME from .pcs.secret.env; when it is empty, runs the rest of the
# arguments as the generator and persists the result. Then mirrors the value
# into the unified .env on EVERY call, minted this run or not — because
# ensure-env-vars-valid.sh rebuilds that file from its sources, so a secret
# minted after that rebuild would otherwise be missing from the file compose
# actually reads. Forgetting that mirror is the bug this function exists to make
# impossible; it was previously re-implemented, and re-explained, in every
# script that owned a secret.
#
# Sets the global variable NAME to the value, so the caller can use it directly:
#
#     ensure_secret AUTHELIA_DEX_SECRET openssl rand -hex 32
#     echo "$AUTHELIA_DEX_SECRET"
#
# Also sets SECRET_MINTED=1 when this call generated the value (0 otherwise),
# for the callers that must react to a first appearance.
#
# The generator runs as a plain command, not through eval: no quoting rules to
# get wrong, and a generator that fails is caught rather than silently producing
# an empty secret.

# Defaults; a caller that has already set these keeps its own.
YND_ROOT="${YND_ROOT:-/DATA/AppData/yundera}"
YND_TEMPLATE="$YND_ROOT/template"
SECRET_ENV="${SECRET_ENV:-$YND_ROOT/.pcs.secret.env}"
UNIFIED_ENV="${UNIFIED_ENV:-$YND_ROOT/.env}"
ENV_MGR="${ENV_MGR:-$YND_TEMPLATE/scripts/tools/env-file-manager.sh}"

ensure_secret() {
    local name="$1"
    shift

    if [ -z "$name" ] || [ $# -eq 0 ]; then
        log_error "ensure_secret: usage: ensure_secret NAME generator [args...]"
        return 1
    fi

    local value
    value="$("$ENV_MGR" get "$name" "$SECRET_ENV")"

    SECRET_MINTED=0
    if [ -z "$value" ]; then
        if ! value="$("$@")" || [ -z "$value" ]; then
            log_error "ensure_secret: generator for $name produced nothing ($*)"
            return 1
        fi
        "$ENV_MGR" set "$name" "$value" "$SECRET_ENV"
        SECRET_MINTED=1
        log_info "Generated $name"
    fi

    "$ENV_MGR" set "$name" "$value" "$UNIFIED_ENV"

    # Assigns the caller's global, since `name` is the only local declared here.
    printf -v "$name" '%s' "$value"
}
