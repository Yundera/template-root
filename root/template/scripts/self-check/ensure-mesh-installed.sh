#!/bin/bash
# ensure-mesh-installed.sh - Install the stock mesh template once, keep its inputs
# current, and run it.
#
# A PCS runs Yundera/mesh-router-template-root UNMODIFIED in /DATA/AppData/mesh:
# the mesh, auth, maison and terminal stacks, with its own self-check, lock, log
# and migrations. This template hands it inputs (the contract in library/mesh.sh,
# doc/mesh-stock-switch.md) and drives it: it pins the mesh version (MESH_REF) and
# the mesh has no cron of its own, so this script is what runs it every night.
#
# EVERY RUN
#   Write the contract into the mesh .env: the keys Yundera is the source of
#   truth for, the PCS constants (the pinned UPDATE_URL among them), and the
#   seed-once keys that are still absent.
#
# INSTALL, through the mesh install.sh, when
#   - the mesh template is not installed yet: a fresh VM, or a box still running
#     this template's former copies of those stacks (adoption);
#   - or the identity changed (PROVIDER_STR / DOMAIN differ from the mesh .env).
#   The installer lays the tree down, writes the identity and runs the mesh
#   self-check. It takes the mesh stack down only on an identity change; adopting
#   a box keeps it serving while its containers are recreated in place.
#   A failed install FAILS THIS SCRIPT, and so a PCS create (PCS_PROVISIONING=1):
#   a PCS whose mesh is not operational is not a PCS. That includes the mesh
#   self-check's check-only steps (root domain reachable, route registered).
#
# OTHERWISE, run the mesh self-check. It is the mesh's only scheduled run
# (SELF_CHECK_CRON=disabled), and it is how a moved MESH_REF arrives: the mesh
# sync downloads the pinned commit and applies its migrations. Once per run of
# this template — nightly, @reboot, or by hand.
#
# ORDERING: after the host steps (users, Docker) and ensure-yundera-user-data.sh,
# which supplies DOMAIN/EMAIL; BEFORE ensure-env-vars-valid.sh, which reads the
# keys the mesh owns (public IP, default app, owner name) back from the mesh .env;
# before every gate this template deploys, since they all register with the mesh
# template's auth-registrar.
set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"
YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/mesh.sh"

PROVIDER_STR="$(ynd_source_get PROVIDER_STR || true)"
DOMAIN="$(ynd_source_get DOMAIN || true)"
EMAIL="$(ynd_source_get EMAIL || true)"
if [ -z "$PROVIDER_STR" ] || [ -z "$DOMAIN" ]; then
    log_error "PROVIDER_STR or DOMAIN is not set in this template's env files; cannot install the mesh template"
    exit 1
fi

PREV_PROVIDER_STR="$(mesh_env_get PROVIDER_STR)"
PREV_DOMAIN="$(mesh_env_get DOMAIN)"

# Before the installer, so its first mesh self-check already runs with Yundera's
# branding, login theme, IP mode, DEFAULT_PWD and secrets instead of minting or
# defaulting its own.
mesh_write_contract

# The dev container shares the HOST's Docker socket: installing there would bind
# 80/443 and create the platform stacks on the developer's machine. The contract
# above is all that can be exercised in it.
if [ -f /.dockerenv ]; then
    log_info "Running in a container; wrote the mesh .env contract, skipping the mesh install"
    exit 0
fi

INSTALL_REASON=""
if ! mesh_installed; then
    if [ -f "$MESH_ROOT/docker-compose.yml" ]; then
        INSTALL_REASON="adopt"
    else
        INSTALL_REASON="fresh"
    fi
elif [ "$PREV_PROVIDER_STR" != "$PROVIDER_STR" ] || [ "$PREV_DOMAIN" != "$DOMAIN" ]; then
    INSTALL_REASON="identity"
fi

if [ -z "$INSTALL_REASON" ]; then
    if [ "$MESH_ENV_CHANGED" = 1 ]; then
        log_info "Mesh inputs changed; running the mesh self-check"
    else
        log_info "Running the mesh self-check"
    fi
    mesh_self_check_now
    exit 0
fi

# --- install --------------------------------------------------------------------

if [ "$INSTALL_REASON" = "adopt" ]; then
    # This template's former mesh-console and auth-console mounted its own tree
    # into empty `template/` mountpoints inside /DATA/AppData/{mesh,auth}. The
    # installer replaces /DATA/AppData/mesh/template with the real tree, so take
    # the two consoles (UIs only — nothing routes through them) off it first;
    # the mesh self-check recreates both from the stock compose.
    log_info "Adopting this box onto the stock mesh template"
    docker rm -f mesh-console-app auth-console-app >/dev/null 2>&1 || true
    # The mesh .env carried this template's "managed keys" header; it is the mesh
    # template's file from now on.
    sed -i "/^# OWNED BY THE 'mesh' STACK\./d; /^# \/DATA\/AppData\/yundera\/template\/scripts\/tools\/deploy-stack.sh sets a fixed list/d; /^# of keys here on every self-check and touches nothing else/d; /^# those, edit its source: \/DATA\/AppData\/yundera\//d" "$MESH_ENV"
fi

INSTALLER_URL="$(mesh_installer_url)"
CHANNEL_URL="$(mesh_channel_url)"
INSTALLER="$(mktemp --suffix=.sh /tmp/mesh-install.XXXXXX)"
trap 'rm -f "$INSTALLER"' EXIT

if ! curl -fsSL --retry 3 --max-time 120 -o "$INSTALLER" "$INSTALLER_URL" \
    || ! head -c 2 "$INSTALLER" | grep -q '^#!'; then
    log_error "Could not fetch the mesh installer from $INSTALLER_URL"
    exit 1
fi

INSTALL_ARGS=(--yes --provider "$PROVIDER_STR" --domain "$DOMAIN" --update-url "$CHANNEL_URL")
[ -n "$EMAIL" ] && INSTALL_ARGS+=(--email "$EMAIL")

log_info "Running the mesh installer ($INSTALL_REASON) from $INSTALLER_URL, channel $CHANNEL_URL"
# A clean environment: the installer lets environment variables outrank its .env
# (UPDATE_URL in particular, which in this template's environment is a template-root
# .zip), so nothing of this run may leak into it.
INSTALL_RC=0
env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" HOME=/root LANG=C.UTF-8 \
    bash "$INSTALLER" "${INSTALL_ARGS[@]}" || INSTALL_RC=$?

if [ "$INSTALL_RC" -ne 0 ]; then
    log_error "The mesh installer failed (exit $INSTALL_RC); see /DATA/AppData/mesh/log/mesh.log"
    exit 1
fi

if [ "$INSTALL_REASON" = "adopt" ]; then
    # Leftovers of this template's former auth stack: the console's mountpoint,
    # and the login theme in the slot it named `yundera` (the stock Dex reads
    # `themes/mesh`, provisioned from DEX_THEME_SRC). Only once nothing binds it.
    rmdir /DATA/AppData/auth/template 2>/dev/null || true
    OLD_THEME="/DATA/AppData/auth/dex/frontend/themes/yundera"
    if [ -d "$OLD_THEME" ] && ! docker container inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' dex 2>/dev/null | grep -qxF "$OLD_THEME"; then
        rm -rf "$OLD_THEME"
    fi
fi

log_info "Mesh template installed ($INSTALL_REASON)"
