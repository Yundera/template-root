#!/bin/bash
# env.sh - the .env a compose project actually reads.
#
#   env_emit_for_compose /DATA/AppData/yundera/docker-compose.yml > .env
#
# A stack's .env holds exactly the keys its own compose file interpolates, taken
# from this template's sources (.pcs.env, .pcs.secret.env, .ynd.user.env) and,
# for the keys the mesh template owns, from the mesh .env. It used to be the
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

# KEY=value lines for the keys COMPOSE_FILE interpolates: the source files'
# lines verbatim (minus any key the mesh owns), then the mesh-owned keys read
# back from the mesh .env, last, so a stale copy from before the switch never
# wins. Prints nothing for a key no source carries — compose reports it unset.
env_emit_for_compose() {
    local compose_file="$1" keys key f read_back="" read_back_keys=""
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

    for f in "${ENV_SOURCES[@]}"; do
        [ -f "$f" ] || continue
        if [ -n "$read_back_keys" ]; then
            grep -E "^(${keys})=" "$f" | grep -Ev "^(${read_back_keys})=" || true
        else
            grep -E "^(${keys})=" "$f" || true
        fi
    done
    printf '%s' "$read_back"
}
