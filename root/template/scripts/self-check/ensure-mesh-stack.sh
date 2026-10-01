#!/bin/bash
# ensure-mesh-stack.sh - Deploy the mesh stack: mesh-router-tunnel, -agent, -caddy,
# smtp, and mesh-console — the stack's web UI (template/stacks/mesh) — to
# /DATA/AppData/mesh.
#
# The first four used to be services of the yundera stack. They are their own project
# now, matching mesh-router-template-root's `mesh` stack, with the same container
# names. Their data (certs, the mesh CA, Caddy's state) is in the stack's own
# folder too, /DATA/AppData/mesh/data — the same relative layout as the mesh
# template.
#
# THE HANDOVER: on the tick that first ships this, the containers still belong to
# the yundera project. deploy-stack.sh pulls first, then evicts them by name and
# brings them up under `mesh` (evict_name_squatters, library/stacks.sh), so the box
# is unreachable only for the length of an `up`. Nothing else is needed, and
# nothing is needed afterwards either: from then on this is an ordinary deploy.
#
# THE DATA MOVE (2026-10-01) rides the same `up`: the migration renames
# /DATA/AppData/yundera/data to /DATA/AppData/mesh/data while the containers keep
# running on it, and this deploy recreates them on the new path. See
# migrations/2026-10-01-10-move-state-into-stack-folders.sh.
#
# ORDERING: FIRST of the stacks. Everything else on the box is reached through
# this Caddy, Dex's on-box issuer pin terminates on it, and mesh-router-agent
# writes the mesh CA (data/ca) that Dex reads. Must run
# after ensure-env-vars-valid.sh, which builds the unified .env deploy-stack.sh
# takes this stack's inputs from.
set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/secrets.sh"

# mesh-console-app mounts this folder read-only and the template tree inside it
# (see its volumes). A mount nested in a read-only one needs its mountpoint to
# exist already — Docker cannot create it — so this empty directory is that
# mountpoint and nothing else.
mkdir -p /DATA/AppData/mesh/template

# The key mesh-console's gate signs its identity assertion with, and the app
# verifies it with. Minted here, right before the stack comes up, so the tick that
# first ships the console starts it with the key; mirrored into the unified .env
# that deploy-stack.sh copies. Unset, the app refuses every request (fails
# closed). Nothing to back up: a new key costs one round of console re-logins.
ensure_secret MESH_CONSOLE_ASSERTION_SECRET openssl rand -hex 32

# THE MESH .env IS THE MESH STACK'S OWN FILE. This template hands it a fixed list
# of inputs and never regenerates it (DEPLOY_ENV_KEYS, tools/deploy-stack.sh) —
# the contract in doc/mesh-stock-switch.md, put in place ahead of the switch so
# that the day the stock mesh template takes this folder over, its .env already
# holds what that template needs and nothing it would trip on.
#
# From the unified .env, when present there:
#   - identity and routing: what the orchestrator and the self-check know
#   - the secrets the mesh template would otherwise mint for itself. Seeding
#     them is what keeps them STABLE across the switch: a second DEFAULT_PWD
#     breaks every installed app, a second DEX_SESSION_KEY logs everyone out.
#   - UPDATE_URL and SELF_CHECK_CRON, FOR NOW. Mesh Console reads both from this
#     file to show the update channel and the schedule, and until the switch
#     those are this template's. At the switch they become the mesh template's
#     own values (a .tar.gz channel) and leave this list.
MESH_ENV_KEYS="PROVIDER_STR DOMAIN EMAIL DEFAULT_PWD LOCAL_ADMIN_USER
    DEFAULT_SERVICE_HOST DEFAULT_SERVICE_PORT
    PUBLIC_IP PUBLIC_IP_DASH PUBLIC_IPV4 PUBLIC_IPV4_DASH PUBLIC_IPV6 PUBLIC_IPV6_DASH
    AUTHELIA_DEX_SECRET DEX_SESSION_KEY MESH_CONSOLE_ASSERTION_SECRET AUTH_CONSOLE_ASSERTION_SECRET
    TERMINAL_ENABLED SMTP_TO APPSTORE_URL OPERATOR_API
    UPDATE_URL SELF_CHECK_CRON"

# Constants: what a Yundera PCS is, expressed in the mesh template's own knobs
# (its README, "Configuration"). Inert while this template still ships its own
# compose files, which hardcode the same values.
DEPLOY_ENV_KEYS="$(echo $MESH_ENV_KEYS)" \
    exec "$YND_TEMPLATE/scripts/tools/deploy-stack.sh" mesh /DATA/AppData/mesh \
    "DATA_ROOT=/DATA" \
    "PUID=1000" \
    "PGID=1000" \
    "PUBLIC_IP_MODE=interface" \
    "TERMINAL_USER=admin" \
    "BRAND_NAME=Yundera" \
    "DEX_THEME_SRC=$YND_TEMPLATE/dex-theme" \
    "PLATFORM_PROJECTS=mesh,auth,yundera,maison,kopia,terminal" \
    "TRUSTED_PUBKEY_HOST_SUFFIXES=yundera.com" \
    "BACKUP_ENGINE_CONTAINER=kopia-engine"
