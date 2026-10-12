#!/bin/bash
# ensure-maison-onboarding.sh - Gate Maison's dashboard on onboarding.
#
# Writes or removes /DATA/AppData/maison/onboarding.json, the one input Maison
# reads to replace its dashboard with "finish setting up this server first". It
# is this template's input to the stock maison stack, which the mesh template
# deploys and never touches this file in: deploy-stack.sh there rewrites only
# docker-compose.yml, .env and the icon in that folder.
#
# ORDERING: after ensure-mesh-installed.sh (the maison folder is the mesh
# template's) and ensure-env-vars-valid.sh (DOMAIN in the unified .env).
#
# Maison's dashboard is the box's root domain, so it is where an owner actually
# lands — and until this existed, landing there walked them straight past
# onboarding into permanent dependence on the operator's SSO. While this file is
# present Maison serves an interstitial instead, pointing at the admin app's
# first-start wizard. Its PRESENCE is the entire state; Maison reads nothing else
# and remembers nothing between requests. See Maison's internal/onboarding.
#
# THIS SCRIPT IS THE AUTHORITY, and it reconciles rather than seeds. `claimed` is
# derived from the user database on every call, so writing the file once at
# provisioning would be a marker, with all the ways a marker drifts: a box
# claimed with `authelia-user-manager.sh claim` never runs the wizard, so nothing
# would ever remove the file and Maison would gate forever on a box that is
# already done; a restored or migrated box carries the auth database and Maison's
# state directory independently, so either half can arrive without the other.
# Reconciling on every tick means the worst case is one self-check of drift, and
# @reboot bounds even that. onboarding.sh's own `rm` on success is only a fast
# path so the gate clears immediately instead of at the next tick.
#
# It is asked, not re-derived: onboarding.sh already owns the definition of
# "claimed" — three copies of that predicate exist and its header says to keep
# them identical, so a fourth would be one too many. It is also the file a
# deployment overrides to redefine onboarding entirely, which means an override
# decides when Maison's gate opens, for free.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"
YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/mesh.sh"

MAISON_DIR="/DATA/AppData/maison"

if [ ! -d "$MAISON_DIR" ]; then
    log_warn "$MAISON_DIR does not exist yet (the mesh template deploys it); nothing to gate"
    exit 0
fi

ONBOARDING_SH="$YND_TEMPLATE/scripts/tools/onboarding.sh"
ONBOARDING_FILE="$MAISON_DIR/onboarding.json"
DOMAIN="$(ynd_source_get DOMAIN || true)"

onboarding_claimed() {
    local out
    [ -x "$ONBOARDING_SH" ] || return 2
    out="$("$ONBOARDING_SH" status 2>/dev/null)" || return 2
    case "$(printf '%s' "$out" | yq -r '.claimed' 2>/dev/null)" in
        true)  return 0 ;;
        false) return 1 ;;
        *)     return 2 ;;
    esac
}

# HOW THE GATE IS SET. A Maison image with the `maison` CLI takes it as its managed
# `onboarding` setting (Maison's docs/config.md): open = release the setting, closed =
# set it. That replaces the file, which is then removed so no stale copy outlives the
# setting. An image older than the CLI — or a dashboard that is not running right
# now — only reads the file, so the file path below stays as it always was. Maison
# reads the file only while it has no `onboarding` setting.
MAISON_CLI=0
if docker exec maison-app maison help >/dev/null 2>&1; then
    MAISON_CLI=1
fi

gate_open() {
    if [ "$MAISON_CLI" = 1 ]; then
        docker exec maison-app maison settings release onboarding >/dev/null \
            || { log_error "Maison refused to release the onboarding gate"; return 1; }
    fi
    rm -f "$ONBOARDING_FILE"
}

gate_close() {
    local url="$1"
    if [ "$MAISON_CLI" = 1 ]; then
        printf '{"url":"%s"}' "$url" \
            | docker exec -i maison-app maison settings set onboarding --owner Yundera >/dev/null \
            || { log_error "Maison refused the onboarding gate"; return 1; }
        rm -f "$ONBOARDING_FILE"
        return 0
    fi
    # Written to a temp file and moved into place for the same reason .env.app
    # is: Maison reads it from another container on every navigation and must
    # never see a half-written one.
    ONBOARDING_TMP="$(mktemp "$MAISON_DIR/onboarding.json.XXXXXX")"
    printf '{"url":"%s"}\n' "$url" > "$ONBOARDING_TMP"
    chmod 644 "$ONBOARDING_TMP"   # no secrets; Maison is the only reader
    mv -f "$ONBOARDING_TMP" "$ONBOARDING_FILE"
}

# Tested context, so `set -e` does not abort on the 1 and 2 answers, which are
# both normal outcomes here rather than failures.
ONBOARDING_RC=0
onboarding_claimed || ONBOARDING_RC=$?

case "$ONBOARDING_RC:$DOMAIN" in
    2:*)
        # Could not find out. Change nothing — both edits are wrong under
        # uncertainty, and leaving the gate as it stands preserves whatever the
        # last confident answer was.
        log_warn "Could not read onboarding status; leaving the Maison gate untouched"
        ;;
    0:*)
        # Claimed: open the gate. Releasing is a no-op when the setting is not
        # managed, so this is safe to repeat every night.
        gate_open && log_info "PCS is onboarded; Maison un-gated"
        ;;
    1:)
        # Unclaimed, but no domain — so there is no admin host to send anyone to
        # and the interstitial's only button would go nowhere. Better an
        # un-gated dashboard than a dead end.
        log_warn "PCS is not onboarded but DOMAIN is empty; leaving Maison un-gated"
        gate_open
        ;;
    1:*)
        # Unclaimed: gate the dashboard, pointing at the admin app's wizard.
        # `admin-${DOMAIN}` bare, with no path — the wizard gates that app's whole
        # shell rather than living on a route, so the host itself is the entry
        # point. Maison appends its own ?return= before linking.
        gate_close "https://admin-$DOMAIN/" \
            && log_info "PCS is not onboarded; Maison gated to https://admin-$DOMAIN/"
        ;;
esac
