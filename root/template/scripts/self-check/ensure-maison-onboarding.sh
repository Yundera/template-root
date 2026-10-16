#!/bin/bash
# ensure-maison-onboarding.sh - Point Maison's dashboard at the onboarding slides.
#
# Maison's dashboard is the box's root domain, so it is where an owner actually lands —
# and until a gate existed, landing there walked them straight past onboarding into
# permanent dependence on the operator's SSO.
#
# THE ADMIN APP IS THE AUTHORITY (since 2026-10-16, Maison 1.1.64 / admin app 2.1.0). This
# script no longer decides anything: it hands Maison a managed `onboarding` setting
#
#   {"check_url":"http://admin-app/api/onboarding/check","token":"${secret:onboarding_token}"}
#
# and Maison asks that URL on every browser navigation. The admin app answers
# {"show":bool,"url":"https://admin-<domain>/"} from its own slide state — account
# claimed, backup set up, each slide skipped for less than three days — and Maison
# redirects (303) when show is true, failing open on any error. The generic half is
# Maison's (its docs/config.md); a FOSS box without this setting sees no change. The
# bearer is ONBOARDING_CHECK_TOKEN, minted by ensure-mesh-installed.sh and also handed to
# the admin-app container: the route is reached over `pcs`, not through the admin gate,
# so the token is what keeps a store app from reading it. Maison holds the value as its
# `onboarding_token` secret, set here every run, so a rotated token converges.
#
# The setting is constant, so this is set-and-forget: claimed or not, the box carries the
# same value, and onboarding.sh no longer has to re-run this to open or close anything.
#
# THE FALLBACK. A Maison older than 1.1.64 decodes the setting strictly and refuses
# check_url; an older template (or a failed mint) may leave no token. Either way this
# falls back to the previous behaviour, reconciled every run: unclaimed => the setting (or,
# with no CLI at all, /DATA/AppData/maison/onboarding.json) `{"url":"https://admin-<domain>/"}`,
# which such a Maison turns into an interstitial; claimed => released / removed. Maison
# 1.1.64 treats a leftover `{"url":…}` as off, so a box that falls back once and upgrades
# later converges at the next run. Claimed is asked of onboarding.sh, never re-derived:
# it owns the predicate (three copies exist; a fourth would be one too many), and it is
# the file a deployment overrides to redefine onboarding.
#
# ORDERING: after ensure-mesh-installed.sh (the maison folder is the mesh template's,
# and the token is minted there) and ensure-env-vars-valid.sh (DOMAIN in the unified .env).

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"
YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/mesh.sh"
# ensure_secret: reads ONBOARDING_CHECK_TOKEN (minted by ensure-mesh-installed.sh).
source "$YND_TEMPLATE/scripts/library/secrets.sh"

MAISON_DIR="/DATA/AppData/maison"

if [ ! -d "$MAISON_DIR" ]; then
    log_warn "$MAISON_DIR does not exist yet (the mesh template deploys it); nothing to gate"
    exit 0
fi

ONBOARDING_SH="$YND_TEMPLATE/scripts/tools/onboarding.sh"
ONBOARDING_FILE="$MAISON_DIR/onboarding.json"
CHECK_URL="http://admin-app/api/onboarding/check"
DOMAIN="$(ynd_source_get DOMAIN || true)"

# Idempotent: returns the value ensure-mesh-installed.sh minted, or mints it if that
# script has not run yet on this box. Never fatal — no token only means the fallback.
ONBOARDING_CHECK_TOKEN=""
ensure_secret ONBOARDING_CHECK_TOKEN openssl rand -hex 32 >/dev/null 2>&1 || ONBOARDING_CHECK_TOKEN=""

# A Maison image with the `maison` CLI takes managed settings; one older than that only
# reads the file. The dashboard not running right now looks the same as the latter.
MAISON_CLI=0
if docker exec maison-app maison help >/dev/null 2>&1; then
    MAISON_CLI=1
fi

# --- the check_url setting (Maison 1.1.64+) -----------------------------------
set_check_url() {
    [ "$MAISON_CLI" = 1 ] || return 1
    [ -n "$ONBOARDING_CHECK_TOKEN" ] || return 1
    local out
    # The token travels on stdin, never in an argv: `ps` on the host shows docker exec's.
    out="$(printf '%s' "$ONBOARDING_CHECK_TOKEN" \
        | docker exec -i maison-app maison secret set onboarding_token 2>&1 >/dev/null)" \
        || { log_warn "Maison refused the onboarding_token secret: $out"; return 1; }
    # A Maison that predates check_url refuses the value (strict decode): that is the
    # signal to fall back, not an error.
    # shellcheck disable=SC2016 # ${secret:…} is Maison's reference syntax, not ours to expand
    out="$(printf '{"check_url":"%s","token":"${secret:onboarding_token}"}' "$CHECK_URL" \
        | docker exec -i maison-app maison settings set onboarding --owner Yundera 2>&1 >/dev/null)" \
        || { log_info "Maison did not take the check_url onboarding setting ($out) - using the legacy gate"; return 1; }
    rm -f "$ONBOARDING_FILE"
}

if set_check_url; then
    log_info "Maison asks the admin app ($CHECK_URL) whether to show onboarding"
    exit 0
fi

# --- fallback: the legacy {url} gate (Maison <= 1.1.62) ------------------------

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

# open = release the setting, closed = set it. That replaces the file, which is then
# removed so no stale copy outlives the setting. Without the CLI, the file is the gate;
# Maison reads it only while it has no `onboarding` setting.
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
    # Written to a temp file and moved into place: Maison reads it from another
    # container on every navigation and must never see a half-written one.
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
        gate_open && log_info "PCS is onboarded; Maison un-gated (legacy gate)"
        ;;
    1:)
        # Unclaimed, but no domain — so there is no admin host to send anyone to
        # and the interstitial's only button would go nowhere. Better an
        # un-gated dashboard than a dead end.
        log_warn "PCS is not onboarded but DOMAIN is empty; leaving Maison un-gated"
        gate_open
        ;;
    1:*)
        # Unclaimed: gate the dashboard, pointing at the admin app's slides.
        # `admin-${DOMAIN}` bare, with no path — the slides gate that app's whole
        # shell rather than living on a route. Maison appends its own ?return=.
        gate_close "https://admin-$DOMAIN/" \
            && log_info "PCS is not onboarded; Maison gated to https://admin-$DOMAIN/ (legacy gate)"
        ;;
esac
