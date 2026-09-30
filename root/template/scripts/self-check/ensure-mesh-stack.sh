#!/bin/bash
# ensure-mesh-stack.sh - Deploy the mesh stack: mesh-router-tunnel, -agent, -caddy
# and smtp (template/stacks/mesh), to /DATA/AppData/mesh.
#
# These four used to be services of the yundera stack. They are their own project
# now, matching mesh-router-template-root's `mesh` stack, with the same container
# names and the same data under /DATA/AppData/yundera/data — see the header of
# stacks/mesh/docker-compose.yml.
#
# THE HANDOVER: on the tick that first ships this, the containers still belong to
# the yundera project. deploy-stack.sh pulls first, then evicts them by name and
# brings them up under `mesh` (evict_name_squatters, library/stacks.sh), so the box
# is unreachable only for the length of an `up`. Nothing else is needed, and
# nothing is needed afterwards either: from then on this is an ordinary deploy.
#
# ORDERING: FIRST of the stacks. Everything else on the box is reached through
# this Caddy, Dex's on-box issuer pin terminates on it, and mesh-router-agent
# writes the mesh CA (data/ca) that the auth stack and every gate read. Must run
# after ensure-env-vars-valid.sh, which builds the .env deploy-stack.sh copies.
set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"

exec "$YND_TEMPLATE/scripts/tools/deploy-stack.sh" mesh /DATA/AppData/mesh
