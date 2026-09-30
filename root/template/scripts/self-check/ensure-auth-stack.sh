#!/bin/bash
# ensure-auth-stack.sh - Deploy the auth stack: dex, authelia, auth-registrar and
# auth-console (template/stacks/auth), to /DATA/AppData/auth.
#
# These three used to be services of the yundera stack. They are their own project
# now — identity as one unit, on this template and on mesh-router-template-root
# alike — with the same container names, and their state still under
# /DATA/AppData/yundera/{auth,dex}. See the header of stacks/auth/docker-compose.yml.
#
# THE HANDOVER: on the tick that first ships this, the containers and the
# `yundera-auth` network still belong to the yundera project. deploy-stack.sh
# evicts the containers by name, which empties the network, then removes it so
# compose recreates it as the auth stack's own (DEPLOY_ADOPT_NETWORKS below,
# adopt_network in library/stacks.sh).
#
# ORDERING, and why each neighbour matters:
#   - AFTER ensure-mesh-stack.sh: Caddy routes auth-* / local-auth-* here, and Dex
#     reads the mesh CA mesh-router-agent writes.
#   - AFTER ensure-authelia.sh, ensure-yundera-login.sh and ensure-dex.sh: they
#     mint the secrets this stack interpolates and render the config files its
#     services read at start. Dex on a missing config.yaml exits immediately.
#   - BEFORE every gate: admin (yundera stack), maison, kopia, terminal all get
#     their OIDC client from auth-registrar.
set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/authelia-ready.sh"
source "$YND_TEMPLATE/scripts/library/secrets.sh"

# `dex` bind-mounts two individual FILES from dex/frontend/templates/. Docker
# creates a missing bind source as a DIRECTORY, after which dex can never start
# ("not a directory"). ensure-dex.sh provisions them, but this runs it again so
# the stack cannot come up without them whatever ran before — and it repairs a
# host already poisoned by an earlier `up`. Tolerant: a missing theme only costs
# the custom login UI and must never stop the stack.
DEX_FRONTEND_TOOL="$YND_TEMPLATE/scripts/tools/provision-dex-frontend.sh"
if [ -x "$DEX_FRONTEND_TOOL" ]; then
    "$DEX_FRONTEND_TOOL" || log_warn "Dex frontend provisioning reported an error; continuing"
fi

# auth-console (the stack's web UI): its gate signs an identity assertion with
# this key and the app verifies it; the app also signs its session-revocation
# requests to the gate with it. Unset, the app refuses every request (fails
# closed). Minted before the deploy, which copies the unified .env into the
# stack's own. Safe to lose: it re-mints and only logs everyone out of the console.
ensure_secret AUTH_CONSOLE_ASSERTION_SECRET openssl rand -hex 32

# The gate runs as 65534 and writes sessions.json through a temp file in this
# directory, so the DIR must be its own — a root- or 1000-owned one makes it log
# "[session] save failed: permission denied" and forget every login on restart
# (the admin gate's wisera incident, see ensure-admin-gate-secret.sh).
AUTH_CONSOLE_GATE_UID=65534
mkdir -p /DATA/AppData/auth/auth-console/gate-data
chown -R "$AUTH_CONSOLE_GATE_UID:$AUTH_CONSOLE_GATE_UID" /DATA/AppData/auth/auth-console/gate-data 2>/dev/null \
    || log_warn "Could not chown auth-console/gate-data to $AUTH_CONSOLE_GATE_UID; the console gate will not persist sessions"

dex_id() { docker container inspect -f '{{.Id}}' dex 2>/dev/null || true; }
DEX_BEFORE="$(dex_id)"

DEPLOY_ADOPT_NETWORKS="yundera-auth" \
    "$YND_TEMPLATE/scripts/tools/deploy-stack.sh" auth /DATA/AppData/auth

# DEX MUST NOT START BEFORE AUTHELIA ANSWERS. Dex opens every connector once, at
# startup, and drops any whose issuer does not answer — for the Local Account
# connector that is Authelia, and "dropped" lasts until Dex restarts, i.e. the
# next nightly self-check (see library/authelia-ready.sh). ensure-authelia.sh and
# ensure-dex.sh already order their own restarts; what they cannot cover is this
# stack recreating BOTH containers at once — the handover tick, or any change to
# the env they share. So when Dex is a new container, wait for Authelia and give
# Dex one more start. A no-op `up` leaves the id unchanged and skips all of it.
DEX_AFTER="$(dex_id)"
if [ -n "$DEX_AFTER" ] && [ "$DEX_AFTER" != "$DEX_BEFORE" ]; then
    wait_for_authelia
    docker restart dex >/dev/null 2>&1 || log_warn "Could not restart dex after the auth stack recreated it"
fi

log_success "Auth stack is up"
