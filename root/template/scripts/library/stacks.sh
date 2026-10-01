#!/bin/bash
# stacks.sh - helpers for the platform compose stacks.
#
# The platform is several compose projects that share one Docker host and one
# `pcs` network (see doc/stack-split.md):
#
#   mesh, auth, maison, terminal   the stock mesh template's (/DATA/AppData/mesh, …)
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
