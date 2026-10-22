#!/bin/bash
# stacks.sh - helpers for the platform compose stacks.
#
# The platform is several compose projects that share one Docker host and one
# `pcs` network (see doc/stack-split.md):
#
#   mesh, auth, maison             the stock mesh template's (/DATA/AppData/mesh, …)
#   yundera  /DATA/AppData/yundera  admin, admin-app   (the root compose)
#   kopia    /DATA/AppData/kopia    (stacks/kopia)
#
# Moving a service from one project to another is the dangerous operation here:
# container names are host-wide, while `up --remove-orphans` and `down` only ever
# see their own project. These helpers are what make such a move a non-event on
# a live box. Sourced by tools/deploy-stack.sh and the yundera stack-up scripts.
#
# Expects log.sh to be sourced already.

YND_ROOT="${YND_ROOT:-/DATA/AppData/yundera}"
YND_TEMPLATE="${YND_TEMPLATE:-$YND_ROOT/template}"

# Create the shared `pcs` network if it does not exist.
#
# Every stack joins it as `external: true` — none owns it. It used to be created
# by the yundera stack, which made every other stack's deploy order-dependent on
# it, and made `down` on that one project a network teardown attempt for the
# whole box. A box provisioned before the split still has the yundera-labelled
# network; joining it as external is fine, so it is left as it is.
#
# CREATED WITH THE YUNDERA PROJECT'S COMPOSE LABELS, for rollback: a pre-split
# template declares `pcs` as the yundera stack's own network, and compose REFUSES
# (an error, not a warning) an existing network with no `com.docker.compose.network`
# label. A plain `docker network create` here would mean a box provisioned on this
# template and rolled back gets no yundera stack at all. With these labels the old
# compose adopts it as if it had made it. Every stack here joins it as external,
# so the labels cost nothing going forward.
ensure_pcs_network() {
    docker network inspect pcs >/dev/null 2>&1 && return 0
    docker network create \
        --label com.docker.compose.network=pcs \
        --label com.docker.compose.project=yundera \
        pcs >/dev/null
}

# Remove any container that holds a `container_name` this compose project claims
# but belongs to a DIFFERENT project (or to none).
#
# Container names are host-wide, and `up --remove-orphans` only sweeps orphans of
# its own project, so a squatter from another project makes `up` abort on
# "Conflict. The container name ... is already in use" — and compose aborts the
# WHOLE up, not just that service. This is also the mechanism of the stack split
# itself: on the tick that first delivers stacks/mesh, the mesh deploy evicts the
# yundera-project mesh-router-caddy & co. and recreates them under `mesh`.
# (Ported from mesh-router-template-root, where a missing eviction took
# watch.nsl.sh fully dark on 2026-09-29.)
#
# The template is authoritative for the names it declares, so the squatter goes.
# Only the container is removed — volumes and bind mounts are left alone. Loud on
# purpose: every eviction outside a planned move is fleet drift worth knowing about.
#
# Reads the project name and names from `docker compose config` (normalised YAML:
# `name:` at the top, `container_name:` per service), so it needs no yq.
#
# Usage: evict_name_squatters [docker compose global args...]
#   e.g. evict_name_squatters --project-directory DIR -f FILE
evict_name_squatters() {
    local config project name owner rc=0
    config="$(docker compose "$@" config 2>/dev/null)" || return 0
    project="$(sed -n 's/^name: *//p' <<<"$config" | head -n 1)"
    [ -n "$project" ] || return 0

    while read -r name; do
        [ -n "$name" ] || continue
        # `container inspect`, not `inspect`: never match an image or volume by name.
        owner="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null)" || continue
        [ "$owner" = "$project" ] && continue
        log_warn "container '$name' is declared by the '$project' stack but belongs to '${owner:-no compose project}' - removing it so '$project' can start"
        docker rm -f "$name" >/dev/null || rc=1
    done < <(sed -n 's/^ *container_name: *//p' <<<"$config" | tr -d "\"'")

    return "$rc"
}

# --- routes ------------------------------------------------------------------------
#
# The yundera and kopia stacks name no domain: their routes are listed in
# stacks/<stack>/routes (`<service>|<name>|<port>` per line) and rendered, once per
# routing domain of the box, into docker-compose.override.yml beside the live stack.
# The domains are the mesh template's (routing_domains in its scripts/library/common.sh),
# read from the ROUTING_DOMAINS value it writes into the mesh .env — so these routes,
# Maison's app routes and the login suffixes are one list. Ported from
# mesh-router-template-root (render_routing_override, stack_compose).

# The mesh template's ROUTING_DOMAINS: `<suffix>[;<label>=<value>...]` per domain,
# comma-separated, primary first. A mesh template that predates it gets the three
# domains every box had before (its own, nip.io, sslip.io), so this template can ship
# first without leaving admin or kopia unrouted. Empty while DOMAIN or PUBLIC_IP_DASH
# is not known.
ynd_routing_domains() {
    local env="${MESH_ROOT:-${DATA_ROOT:-/DATA}/AppData/mesh}/.env" value domain ip
    [ -f "$env" ] || return 0
    _ynd_mesh_key() { sed -n "s/^$1=//p" "$env" | tail -n 1 | tr -d "\r\"'"; }
    value="$(_ynd_mesh_key ROUTING_DOMAINS)"
    if [ -z "$value" ]; then
        domain="$(_ynd_mesh_key DOMAIN)" ip="$(_ynd_mesh_key PUBLIC_IP_DASH)"
        [ -n "$domain" ] && [ -n "$ip" ] \
            && value="$domain;import=gateway_tls,$ip.nip.io;import=gateway_tls,$ip.sslip.io"
    fi
    printf '%s' "$value"
}

# render_routing_override <domains> <routes-file> <out>
#
# The stack's routes as Caddy labels, one group per route per domain. Written only when
# it changes. With <domains> empty nothing is written, so the stack keeps the routes it
# had — and a box whose mesh template predates ROUTING_DOMAINS keeps the ones in its
# compose file, if that file still has them.
render_routing_override() {
    local domains="$1" spec="$2" out="$3"
    local svc name port entry suffix l n tmp
    local -a services=() entries=() kv=()
    local -A labels=() count=()
    [ -n "$domains" ] && [ -f "$spec" ] || return 0
    IFS=',' read -ra entries <<<"$domains"
    while IFS='|' read -r svc name port; do
        svc="${svc//[[:space:]]/}" name="${name//[[:space:]]/}" port="${port//[[:space:]]/}"
        case "$svc" in "" | \#*) continue ;; esac
        if [ -z "${count[$svc]+set}" ]; then
            services+=("$svc")
            count[$svc]=0
        fi
        for entry in "${entries[@]}"; do
            suffix="${entry%%;*}"
            n="${count[$svc]}"
            labels[$svc]+="      caddy_$n: $name-$suffix"$'\n'
            if [ "$entry" != "$suffix" ]; then
                IFS=';' read -ra kv <<<"${entry#*;}"
                for l in "${kv[@]}"; do
                    labels[$svc]+="      caddy_$n.${l%%=*}: ${l#*=}"$'\n'
                done
            fi
            labels[$svc]+="      caddy_$n.reverse_proxy: \"{{upstreams $port}}\""$'\n'
            count[$svc]=$((n + 1))
        done
    done < <(tr -d '\r' <"$spec")

    tmp="$(mktemp)"
    {
        echo "# GENERATED by template-root from the box's routing domains and"
        echo "# $(basename "$(dirname "$spec")")/routes — rewritten on every self-check, do not edit."
        echo "services:"
        for svc in "${services[@]}"; do
            printf '  %s:\n    labels:\n%s' "$svc" "${labels[$svc]}"
        done
    } >"$tmp"
    if cmp -s "$tmp" "$out"; then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$out"
    chmod 644 "$out"
    echo "Updated $out from the routing domains"
}

# stack_compose <dir> <compose args...> — docker compose on a stack folder with its
# routes: -f disables compose's own lookup of docker-compose.override.yml, so a caller
# that names the compose file names the override too.
stack_compose() {
    local dir="$1"
    shift
    local -a files=(-f "$dir/docker-compose.yml")
    [ -f "$dir/docker-compose.override.yml" ] && files+=(-f "$dir/docker-compose.override.yml")
    docker compose --project-directory "$dir" "${files[@]}" "$@"
}
