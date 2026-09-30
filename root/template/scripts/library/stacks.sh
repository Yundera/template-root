#!/bin/bash
# stacks.sh - helpers for the platform compose stacks.
#
# The platform is several compose projects that share one Docker host and one
# `pcs` network (see doc/stack-split.md):
#
#   mesh     /DATA/AppData/mesh     tunnel, agent, caddy, smtp, mesh-console (stacks/mesh)
#   auth     /DATA/AppData/auth     dex, authelia, auth-registrar (stacks/auth)
#   yundera  /DATA/AppData/yundera  admin, admin-app            (the root compose)
#   + maison, kopia, terminal
#
# Moving a service from one project to another is the dangerous operation here:
# container names are host-wide, while `up --remove-orphans` and `down` only ever
# see their own project. These helpers are what make such a move a non-event on
# a live box. Sourced by tools/deploy-stack.sh and the yundera stack-up scripts.
#
# Expects log.sh to be sourced already.

YND_ROOT="${YND_ROOT:-/DATA/AppData/yundera}"
YND_TEMPLATE="${YND_TEMPLATE:-$YND_ROOT/template}"

# The platform stacks shipped under template/stacks/ that took services over from
# the yundera project. Read by yundera_handover_pending below.
PLATFORM_HANDOVER_STACKS="mesh auth"

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

# Hand a named network over to <project> when another project created it.
#
# Compose only WARNS when a project declares a network another project created,
# and then uses it (verified on compose v5.3.1) — so nothing breaks, but the
# stale owner label stays forever: the warning repeats on every up, and the old
# owner's `down` is the one that would try to delete it. Removing it while it is
# empty lets compose recreate it with the right labels on the next `up`.
#
# Run it AFTER evict_name_squatters, which is what empties it on the tick a
# stack takes a network over. A network that still has containers attached is
# left alone: it is in use, and the warning is harmless.
#
# Usage: adopt_network <network-name> <project>
adopt_network() {
    local net="$1" project="$2" owner attached
    owner="$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$net" 2>/dev/null)" || return 0
    [ "$owner" = "$project" ] && return 0
    attached="$(docker network inspect -f '{{len .Containers}}' "$net" 2>/dev/null || echo 1)"
    if [ "$attached" != "0" ]; then
        log_warn "network '$net' belongs to '${owner:-no compose project}', not '$project', and is still in use - leaving it"
        return 0
    fi
    log_info "network '$net' belonged to '${owner:-no compose project}' - removing it so '$project' recreates it"
    docker network rm "$net" >/dev/null || return 1
}

# True (exit 0) while a yundera-project container still runs a service that one of
# PLATFORM_HANDOVER_STACKS now declares — i.e. the move out of the yundera stack has
# not completed on this box.
#
# The yundera stack-up must NOT pass --remove-orphans then: those containers ARE
# the box's routing and login until mesh/auth take them over, and removing them
# early leaves it dark. That window is real, not theoretical: on the tick that
# first delivers the split, self-check.sh finishes its first pass over the OLD
# scripts-config.txt, which brings the yundera stack up (from the new, admin-only
# compose) before ensure-mesh-stack.sh has ever run. It also covers a mesh or auth
# deploy that failed. Once the owning stack has evicted them, nothing matches and
# orphan removal resumes.
yundera_handover_pending() {
    local stack svc names="" running
    for stack in $PLATFORM_HANDOVER_STACKS; do
        [ -f "$YND_TEMPLATE/stacks/$stack/docker-compose.yml" ] || continue
        # --env-file /dev/null: only the service keys are wanted; unset variables
        # are warnings, not errors, for `config --services`.
        names+=" $(docker compose -f "$YND_TEMPLATE/stacks/$stack/docker-compose.yml" \
            --env-file /dev/null config --services 2>/dev/null | tr '\n' ' ')"
    done
    running="$(docker ps -a --filter label=com.docker.compose.project=yundera \
        --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null)"
    for svc in $running; do
        case " $names " in *" $svc "*) return 0 ;; esac
    done
    return 1
}

# Sets ORPHANS_FLAG to the --remove-orphans flag for the yundera stack's up/down,
# or to nothing while a handover is pending (see above). A variable rather than
# output because log_* writes to stdout.
#
#   yundera_orphans_flag; docker compose ... up -d $ORPHANS_FLAG
yundera_orphans_flag() {
    if yundera_handover_pending; then
        log_warn "yundera stack still holds services now owned by the mesh/auth stacks - not removing orphans until they are taken over"
        ORPHANS_FLAG=""
    else
        ORPHANS_FLAG="--remove-orphans"
    fi
}
