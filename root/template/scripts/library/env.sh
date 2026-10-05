#!/bin/bash
# env.sh - the .env a compose project actually reads.
#
#   env_emit_for_compose /DATA/AppData/yundera/docker-compose.yml \
#       /DATA/AppData/yundera/.stack.env > .env
#
# A stack's .env holds exactly the keys its own compose file interpolates, taken
# from this template's sources (.pcs.env, .pcs.secret.env, .ynd.user.env), the
# stack's own .stack.env and, for the keys the mesh template owns, the mesh .env. It used to be the
# whole union of the three files, copied into every stack folder — so the kopia
# folder carried USER_JWT, PROVIDER_STR, DEFAULT_PWD and the S3 keys while its
# compose read two of them. Deriving the list from the compose file means there is
# no list to keep in step: a new ${VAR} in a compose file is delivered as soon as a
# source carries it.
#
# Only ${NAME} references count (both compose files use braces throughout); a
# $${NAME} escape is compose's literal dollar and is not one, and neither is a
# reference inside a comment line — so a comment naming ${USER_JWT} cannot pull a
# secret into the file.
#
# Expects log.sh to be sourced already.

YND_ROOT="${YND_ROOT:-/DATA/AppData/yundera}"
YND_TEMPLATE="${YND_TEMPLATE:-$YND_ROOT/template}"
source "$YND_TEMPLATE/scripts/library/mesh.sh"

# Source files, in the precedence the generated .env gives them: a later file's
# line comes after an earlier one's, and compose keeps the last.
ENV_SOURCES=("$YND_ROOT/.pcs.env" "$YND_ROOT/.pcs.secret.env" "$YND_ROOT/.ynd.user.env")

# The variable names a compose file interpolates, one per line, unique.
compose_env_keys() {
    grep -vE '^[[:space:]]*#' "$1" \
        | grep -oE '(^|[^$])\$\{[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/.*\$\{//' | sort -u
}

# --- per-stack state: <stack>/.stack.env ---------------------------------------
#
# A value minted or fetched ON THE BOX for ONE stack lives in that stack's own
# folder, in .stack.env: ADMIN_ASSERTION_SECRET in /DATA/AppData/yundera, the
# BACKUP_* credential in /DATA/AppData/kopia. Only that stack's ensure-scripts
# write it, and nothing regenerates it — unlike the stack's .env, which is
# rebuilt from it (env_emit_for_compose below) on every deploy. The hand-off
# files (.pcs.env, .pcs.secret.env, .ynd.user.env) keep only what comes from
# outside the box or is shared between stacks.

# Set KEY=VALUE in a .stack.env, creating it 600 first: env-file-manager.sh
# would otherwise create it at the umask (644), and it holds secrets. An existing
# file keeps its mode and owner (env-file-manager.sh restores both).
stack_env_set() {
    local key="$1" value="$2" file="$3"
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")"
        install -m 600 /dev/null "$file"
    fi
    "$YND_TEMPLATE/scripts/tools/env-file-manager.sh" set "$key" "$value" "$file" >/dev/null
}

# Move KEYs out of a hand-off file into a stack's .stack.env. Idempotent; done by
# the scripts that consume the keys rather than by a migration, so it also
# happens on a frozen box (UPDATE_URL=frozen/local runs no migrations) and the
# script and the state can never disagree.
#
#   stack_env_adopt <legacy-file> <stack-env> KEY...
#
# - a key only in LEGACY is copied to STACK, read back, then deleted from LEGACY;
# - a key in both is deleted from LEGACY: STACK wins;
# - before LEGACY is first modified, it is copied whole to
#   <legacy>.<YYYY-MM-DD>.old (600, kept). A template rollback finds the keys
#   gone and mints new ones; the values stay recoverable from that copy.
stack_env_adopt() {
    local legacy="$1" stack="$2"
    shift 2
    local mgr="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"
    local key value current snapshot=""
    [ -f "$legacy" ] || return 0

    for key in "$@"; do
        "$mgr" exists "$key" "$legacy" 2>/dev/null || continue
        value="$("$mgr" get "$key" "$legacy")"

        if [ -z "$snapshot" ]; then
            snapshot="$legacy.$(date +%F).old"
            if [ ! -e "$snapshot" ]; then
                cp -p "$legacy" "$snapshot"
                chmod 600 "$snapshot"
                log_info "Saved $(basename "$legacy") as $(basename "$snapshot") before moving keys out"
            fi
        fi

        if "$mgr" exists "$key" "$stack" 2>/dev/null; then
            current="$("$mgr" get "$key" "$stack")"
            [ "$current" = "$value" ] || log_warn "$key differs between $(basename "$legacy") and $stack - keeping $stack's"
        elif [ -n "$value" ]; then
            stack_env_set "$key" "$value" "$stack"
            if [ "$("$mgr" get "$key" "$stack")" != "$value" ]; then
                log_error "stack_env_adopt: $key did not read back from $stack - leaving it in $(basename "$legacy")"
                return 1
            fi
            log_info "Moved $key from $(basename "$legacy") to $stack"
        fi
        "$mgr" delete "$key" "$legacy" >/dev/null
    done
}

# KEY=value lines for the keys COMPOSE_FILE interpolates: the source files'
# lines verbatim (minus any key the mesh owns), then the stack's own .stack.env
# when one is given (it wins over the hand-off files), then the mesh-owned keys
# read back from the mesh .env, last, so a stale copy from before the switch
# never wins. Prints nothing for a key no source carries — compose reports it
# unset. The .stack.env goes through the same filter: kopia's holds the BACKUP_*
# credential, which its compose never references, so none of it reaches .env.
#
#   env_emit_for_compose <compose-file> [<stack-env>]
env_emit_for_compose() {
    local compose_file="$1" stack_env="${2:-}" keys key f read_back="" read_back_keys=""
    if [ ! -f "$compose_file" ]; then
        log_error "env_emit_for_compose: compose file not found: $compose_file"
        return 1
    fi
    keys="$(compose_env_keys "$compose_file" | paste -sd'|' -)"
    [ -n "$keys" ] || return 0

    if [ -f "$MESH_ENV" ]; then
        for key in $MESH_KEYS_READ_BACK; do
            grep -qxE "$keys" <<<"$key" || continue
            mesh_env_has "$key" || continue
            read_back+="${key}=$(mesh_env_get "$key")"$'\n'
        done
    fi
    read_back_keys="$(printf '%s' "$read_back" | cut -d= -f1 | paste -sd'|' -)"

    for f in "${ENV_SOURCES[@]}" ${stack_env:+"$stack_env"}; do
        [ -f "$f" ] || continue
        if [ -n "$read_back_keys" ]; then
            grep -E "^(${keys})=" "$f" | grep -Ev "^(${read_back_keys})=" || true
        else
            grep -E "^(${keys})=" "$f" || true
        fi
    done
    printf '%s' "$read_back"
}
