#!/bin/bash
# preinstall-apps.sh — install the apps this PCS ships with, once, at provisioning.
#
# Reads PREINSTALL_APPS (staged by the orchestrator into .pcs.env, folded into the
# unified .env by ensure-env-vars-valid.sh) and asks Maison to install each one
# through its ordinary store-install API — the exact endpoint the dashboard's
# Install button calls.
#
# The result is an app indistinguishable from one the user installed by hand:
# Maison writes /DATA/AppData/<app>/ with the store's docker-compose.yml byte for
# byte, the seed tree, the icon, a prefilled .env, and the x-compose-app update
# reference — so backup, restore, update and uninstall all work on it afterwards.
# Nothing here writes app files itself. (It used to: the orchestrator copied compose
# files into /DATA/AppData/casaos/apps/<app> and drove the CasaOS install API. That
# tree and that API are both gone with CasaOS, so preinstall silently installed
# nothing from the Maison switch until this script replaced it.)
#
# ONE-SHOT, NOT A SELF-CHECK. It is invoked from os-init.sh, which runs exactly
# once per VM lifecycle, alongside clear-root-ssh-keys.sh and lock-password-auth.sh.
# That is the whole guard — no marker file is needed, and none should be added.
# A recurring "ensure these apps exist" check would reinstall, every night, an app
# the user had deliberately uninstalled. "Preinstalled" means the box shipped with
# it, not that the box must always have it.
#
# ORDERING: must run AFTER self-check-reboot.sh has completed inside os-init.sh —
# ensure-maison-stack.sh is what brings Maison up, and there is nothing to install
# into before it has. Placed at the very end of os-init.sh, after the SSH-key
# handover block: this is the least critical step on the box and the only one that
# touches the network, and it has no business delaying an irreversible handover.
#
# NEVER FAILS THE PROVISION. os-init.sh runs under `set -e`, so a non-zero exit
# here would abort a PCS create over a missing dashboard tile. Every failure is
# logged and this script still exits 0.

set -uo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

if [ -f /.dockerenv ]; then
    log "Inside Docker - dev environment detected. Skipping preinstall."
    exit 0
fi

ENV_MANAGER="$YND_ROOT/scripts/tools/env-file-manager.sh"

# Maison's API container. NOT the `maison` container in front of it — that is the
# AppShield gate, and it answers every unauthenticated request with a 302 to
# /nhl-auth/oidc/login. maison-app has no auth of its own (see the SECURITY note in
# ensure-maison-stack.sh) and is only reachable on the docker network, which is why
# a plain local call works and why its port is never published.
MAISON_CONTAINER="maison-app"
MAISON_PORT="8080"

# Maison dispatches by Host: an unrecognised one gets the per-app launch gate
# instead of the dashboard API. Any dashboard-ish host does; localhost is the
# least surprising.
API_HOST="localhost"

# How long to wait for Maison's API to answer at all. It is already up by the time
# os-init.sh reaches this point — the self-check brought the stack up several
# scripts ago — so this is a formality, not the ten-minute wait the CasaOS-era
# installer needed.
READY_TIMEOUT=120

# How long to keep reporting install progress before returning. Purely for
# visibility in the orchestrator's create log: Maison installs on a background
# context of its own, so hitting this deadline means "still going", not "failed",
# and the app finishes either way.
SETTLE_TIMEOUT=180

PREINSTALL_APPS="$("$ENV_MANAGER" get PREINSTALL_APPS "$YND_ROOT/.env")"
if [ -z "$PREINSTALL_APPS" ]; then
    PREINSTALL_APPS="$("$ENV_MANAGER" get PREINSTALL_APPS "$YND_ROOT/.pcs.env")"
fi

if [ -z "$PREINSTALL_APPS" ]; then
    log "PREINSTALL_APPS is empty - nothing to preinstall"
    exit 0
fi

log "Preinstalling apps: $PREINSTALL_APPS"

MAISON_IP="$(docker inspect "$MAISON_CONTAINER" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | head -1)"

if [ -z "$MAISON_IP" ]; then
    log_error "Container '$MAISON_CONTAINER' has no IP address (is the Maison stack up?)"
    log_error "Skipping preinstall of: $PREINSTALL_APPS"
    exit 0
fi

API="http://$MAISON_IP:$MAISON_PORT/api"

# api_get <path> — GET against Maison's dashboard API, printing the body.
api_get() {
    curl -sf -m 15 -H "Host: $API_HOST" "$API/$1"
}

log "Waiting for Maison's API at $API (up to ${READY_TIMEOUT}s)..."
ready=0
waited=0
while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if api_get apps >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 5
    waited=$((waited + 5))
done

if [ "$ready" -ne 1 ]; then
    log_error "Maison's API did not answer after ${READY_TIMEOUT}s"
    log_error "Skipping preinstall of: $PREINSTALL_APPS"
    exit 0
fi
log "Maison's API is ready (after ${waited}s)"

# parse_ref <reference> — split one PREINSTALL_APPS entry into the three pieces the
# install endpoint takes, mirroring appstore.ParseRef in Maison.
#
# The grammar is Maison's own, separator "/-/", and it is the same string the
# dashboard puts in a store deep link — so a locator can be copied straight out of
# the store panel's address bar:
#
#   Guide                                                  merged catalog (the box's
#                                                          configured stores)
#   Apps/Guide                                             ditto, explicit folder
#   github.com/Yundera/AppStore/archive/refs/heads/main.zip/-/Apps/Guide
#                                                          that store, pinned
#
# A locator is worth preferring for anything that matters. It is fetched on demand
# rather than read from the merged catalog — which Maison refreshes asynchronously
# at startup, so a bare id can lose a race with its own boot and 404. It also needs
# no store to be configured on the box, and it is recorded as the app's update
# reference, so later updates keep coming from the same store.
#
# Split on the LAST "/-/", as Maison does: GitLab archive URLs contain one.
parse_ref() {
    local ref="$1" rest
    ref_store=""
    ref_apps=""
    ref_id=""

    case "$ref" in
        */-/*)
            ref_store="${ref%/-/*}"
            rest="${ref##*/-/}"
            ;;
        *)
            rest="$ref"
            ;;
    esac

    # Everything before the last slash is the apps folder, the last segment is the
    # app — appstore.splitInZip. No slash means no folder, and Maison's default.
    ref_id="${rest##*/}"
    if [ "$ref_id" != "$rest" ]; then
        ref_apps="${rest%/*}"
    fi
}

installed=""
requested=0
accepted=0

IFS=',' read -ra REFS <<< "$PREINSTALL_APPS"
for raw_ref in "${REFS[@]}"; do
    ref="$(echo "$raw_ref" | xargs)"   # trim surrounding whitespace
    [ -z "$ref" ] && continue
    requested=$((requested + 1))

    parse_ref "$ref"
    if [ -z "$ref_id" ]; then
        log_error "[$requested] Unparseable reference: '$ref'"
        continue
    fi

    url="$API/store/$ref_id/install"
    sep="?"
    if [ -n "$ref_store" ]; then
        url="$url${sep}store=$ref_store"
        sep="&"
    fi
    if [ -n "$ref_apps" ]; then
        url="$url${sep}apps_path=$ref_apps"
    fi

    # A pinned store is fetched here if the box has never seen it (tens of MB), so
    # allow more than the readiness probe does. The install itself is detached —
    # this call returns 202 as soon as Maison has accepted it.
    response="$(curl -s -m 180 -X POST -H "Host: $API_HOST" -w $'\n%{http_code}' "$url" 2>&1)"
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$code" != "202" ]; then
        log_error "[$requested] FAILED to install '$ref' (HTTP ${code:-none}): $body"
        continue
    fi

    # Maison answers with the resolved compose project name, which is the app's
    # tile id and need not match the store id (the compose file's own `name:` wins).
    # Take it from the response rather than guessing it.
    project="$(echo "$body" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    [ -z "$project" ] && project="$ref_id"

    accepted=$((accepted + 1))
    installed="$installed $project"
    log "[$requested] Accepted: $ref -> $project"
done

log "Requested $requested app(s), $accepted accepted by Maison"

if [ -z "$installed" ]; then
    exit 0
fi

# Report progress until every accepted install settles, or the deadline passes.
#
# Nothing here can fail the provision: a tile still installing at the deadline goes
# on installing inside Maison, and a tile that errored keeps its install_error on
# the dashboard for the user (and support) to see.
log "Waiting up to ${SETTLE_TIMEOUT}s for installs to settle..."
deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
pending="$installed"

while [ -n "$pending" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    snapshot="$(api_get apps 2>/dev/null)"
    if [ -z "$snapshot" ]; then
        sleep 5
        continue
    fi

    still=""
    for project in $pending; do
        # One tile per fragment: apps.App is entirely flat, so splitting the array
        # on "{" yields one object per line and no JSON parser is needed (jq is not
        # among the packages the template installs).
        fragment="$(printf '%s' "$snapshot" | tr '{' '\n' | grep -F "\"id\":\"$project\"" | head -1)"

        case "$fragment" in
            "")
                # Not on the list yet — the installer's placeholder tile appears
                # within a tick, so this is the very start of the install.
                still="$still $project"
                ;;
            *'"install_error"'*)
                detail="$(echo "$fragment" | sed -n 's/.*"install_error":"\([^"]*\)".*/\1/p')"
                log_error "$project: install FAILED: ${detail:-unknown error}"
                ;;
            *'"installing":true'*)
                still="$still $project"
                ;;
            *)
                log "$project: installed"
                ;;
        esac
    done

    pending="$still"
    [ -n "$pending" ] && sleep 5
done

for project in $pending; do
    log_warn "$project: still installing at the deadline - Maison is continuing in the background"
done

exit 0
