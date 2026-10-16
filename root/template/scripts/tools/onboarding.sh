#!/bin/bash
# onboarding.sh - First-run onboarding hook for a fresh PCS.
#
# THE POINT OF THIS FILE IS THAT IT IS REPLACEABLE. The admin app's first-start
# wizard collects a credential and calls this script; what "onboarding" actually
# means is decided here, on the host, not in the product. A FOSS or white-label
# deployment swaps this one file and changes the whole flow without touching the
# dashboard, the same way dex/connectors.d lets a deployment add a login method
# the template knows nothing about.
#
# Usage:
#   onboarding.sh status                 -> JSON state, safe to poll
#   onboarding.sh run                    -> perform onboarding (password on stdin)
#   onboarding.sh mark-completed         -> record that the wizard was seen
#   onboarding.sh reset --confirm        -> back to unclaimed, so the wizard replays
#
# STDOUT IS A MACHINE INTERFACE. Every subcommand prints JSON and nothing else;
# diagnostics go to stderr and a non-zero exit carries the reason. Identical
# contract to authelia-user-manager.sh, so the dashboard parses both with the
# same helper (Onboarding.ts / AutheliaUsers.ts run()).
#
# `run` inputs:
#   ONBOARDING_USERNAME       (env, required)  the login name the owner chose
#   ONBOARDING_DISPLAYNAME    (env, optional)  defaults to "Administrator"
#   ONBOARDING_GENERATE       (env, optional)  "1" = mint a password instead of
#                                              reading one, returned once in JSON
#   password                  (STDIN)          unless ONBOARDING_GENERATE=1
#
# WHY THE PASSWORD IS ON STDIN AND NOT IN THE ENVIRONMENT. The admin app reaches
# the host by base64-ing its whole command into an ssh argv (HostExecutor.ts), so
# a `FOO=secret onboarding.sh` would sit decodable in `ps` on both the container
# and the host. Everything non-secret travels in env; the secret travels in band.
# Whatever replaces this file must keep that split.
#
# TWO DIFFERENT QUESTIONS, deliberately not conflated:
#
#   claimed    - is there a usable local credential? DERIVED, never cached: it is
#                "at least one non-disabled user in users_database.yml", the same
#                predicate the mesh ensure-authelia.sh gates the Local Account
#                connector on.
#   completed  - has the wizard been through once? A MARKER FILE, and purely
#                cosmetic.
#
# Deriving the first is what keeps a restored backup or a migrated PCS honest. A
# marker is state that drifts: migration copies /DATA/AppData/auth/authelia/ to the
# destination box, so a marker-driven wizard would either nag forever on a claimed
# box or — much worse — refuse to appear on an unclaimed one, leaving an owner with
# no credential, no Local Account connector, and no way to make one. Being wrong
# about `completed` costs a redundant welcome screen.
#
# MARKER LOCATION IS LOAD-BEARING. /DATA/AppData/yundera/ is user data: backed up,
# and carried across by the migration pipeline. It must NOT go under
# /DATA/AppData/yundera/ — ensure-template-sync.sh rsyncs that tree
# from the template on every update and root/.ignore preserves only the env files,
# logs, *.backup and migration-markers/. A marker there vanishes overnight.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
AUTH_ROOT="/DATA/AppData/auth/authelia"
USERS_DB="$AUTH_ROOT/users_database.yml"

ONBOARDING_ROOT="/DATA/AppData/yundera/onboarding"
COMPLETED_MARKER="$ONBOARDING_ROOT/completed"

# Maison's legacy first-run gate file (Maison without the CLI). Since 2026-10-16 Maison
# asks the admin app on every navigation whether to show onboarding (the `onboarding`
# check_url setting, ensure-maison-onboarding.sh), and the admin app answers from this
# script's `status` — so claiming or resetting here takes effect on the very next page
# load without re-running anything. The file is only removed on `run`, so a stale
# copy cannot outlive the claim on a box still on the legacy gate; the self-check
# reconciles that gate every run anyway.
MAISON_ONBOARDING="/DATA/AppData/maison/onboarding.json"

ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"
PCS_ENV="$YND_ROOT/.pcs.env"

# The local accounts are the mesh template's (Authelia, its user manager, its
# Dex render); this script is Yundera's onboarding state around them. The owner
# name lives in the mesh .env, written there by the claim.
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/mesh.sh"
USER_MGR="$MESH_SCRIPTS/tools/authelia-user-manager.sh"

# --- deployment override ------------------------------------------------------
# Same seam as dex/connectors.d: the override lives in the RUNTIME data dir, not
# the template tree, so ensure-template-sync.sh's rsync cannot revert it. Editing
# this file in place on a live PCS would look like it worked and then silently
# disappear at the next nightly sync — that is the trap this exists to avoid.
OVERRIDE="/DATA/AppData/yundera/onboarding.d/onboarding.sh"
if [ -x "$OVERRIDE" ] && [ "$(readlink -f "$OVERRIDE")" != "$(readlink -f "$0")" ]; then
    exec "$OVERRIDE" "$@"
fi

error() {
    echo "ERROR: $1" >&2
    exit 1
}

command -v yq >/dev/null 2>&1 || error "yq not found (installed by self-check/ensure-common-tools-installed.sh)"

# Claimed = at least one user that is not disabled. Kept identical to is_claimed
# in authelia-user-manager.sh and the check in the mesh
# ensure-authelia.sh — if you change one, change all three.
is_claimed() {
    local enabled
    [ -f "$USERS_DB" ] || return 1
    enabled="$(yq '[.users[] | select(.disabled != true)] | length' "$USERS_DB" 2>/dev/null || echo 0)"
    [ "${enabled:-0}" -gt 0 ] 2>/dev/null
}

cmd_status() {
    local claimed="false" completed="false" username=""

    is_claimed && claimed="true"
    [ -f "$COMPLETED_MARKER" ] && completed="true"

    # Best-effort: the recorded owner, so the wizard can greet a returning user.
    username="$(mesh_env_get LOCAL_ADMIN_USER)"
    if [ -z "$username" ] && is_claimed; then
        username="$(yq -r '[.users | to_entries[] | select(.value.disabled != true)][0].key // ""' "$USERS_DB" 2>/dev/null || echo "")"
    fi

    C="$claimed" D="$completed" U="$username" yq -o=json -I=0 -n \
        '{"claimed": (strenv(C) == "true"), "completed": (strenv(D) == "true"), "username": strenv(U)}'
}

cmd_mark_completed() {
    mkdir -p "$ONBOARDING_ROOT"
    printf 'completed at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$COMPLETED_MARKER"
    chmod 644 "$COMPLETED_MARKER"
    yq -o=json -I=0 -n '{"completed": true}'
}

# The default implementation of "onboard this PCS": name the owner account, set
# its password, enable it. Everything else a deployment might want — seeding
# apps, registering a domain, writing operator config — belongs in an override,
# which is why this stays deliberately thin.
cmd_run() {
    local username="${ONBOARDING_USERNAME:-}"
    local displayname="${ONBOARDING_DISPLAYNAME:-Administrator}"
    local generate="${ONBOARDING_GENERATE:-0}"

    [ -n "$username" ] || error "ONBOARDING_USERNAME is required"
    [ -x "$USER_MGR" ] || error "$USER_MGR not found or not executable"

    # Idempotent by refusal rather than by re-running: claiming twice would
    # rename the owner account, and the username is the OIDC preferred_username
    # every app keys its per-user account on. See doc/pcs-onboarding.md.
    if is_claimed; then
        error "this PCS is already onboarded; manage accounts from the Account panel instead"
    fi

    local claim_out
    if [ "$generate" = "1" ]; then
        claim_out="$("$USER_MGR" claim --generate "$username" "$displayname")" \
            || error "claim failed"
    else
        # Read the secret from OUR stdin and hand it to claim on ITS stdin, so it
        # never lands in an argv or an environment on either hop.
        local plaintext=""
        IFS= read -r plaintext || true
        [ -n "$plaintext" ] || error "no password on stdin (or set ONBOARDING_GENERATE=1)"
        claim_out="$(printf '%s' "$plaintext" | "$USER_MGR" claim "$username" "$displayname")" \
            || error "claim failed"
        unset plaintext
    fi

    # Only now — a half-finished onboarding must be re-runnable.
    mkdir -p "$ONBOARDING_ROOT"
    printf 'completed at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$COMPLETED_MARKER"
    chmod 644 "$COMPLETED_MARKER"

    # Nothing to tell Maison: it asks the admin app on the next navigation, and the
    # admin app refreshes its answer after this returns. Only the legacy gate file
    # is cleared here, best-effort.
    rm -f "$MAISON_ONBOARDING" 2>/dev/null || true

    # Pass the claim's JSON straight through (it carries the generated password
    # when there is one) with the marker state folded in.
    printf '%s' "$claim_out" | yq -o=json -I=0 '. + {"completed": true}'
}

# The inverse of `run`: put the box back into the unclaimed state so the wizard
# is reachable again. For testing and for re-provisioning a box by hand.
#
# ALSO EXPOSED in the admin app ("Re-run onboarding", POST
# /api/admin/onboarding-reset). Unclaiming is a self-lockout button: the mesh
# ensure-authelia.sh withdraws the Local Account connector, so on a PCS whose Yundera Login is absent
# or broken the only way back in is the support SSH key. The route refuses while
# Yundera Login is off, requires a typed confirmation, and revokes the other admin
# gate sessions; from a terminal none of that applies, so --confirm stays
# mandatory here. See doc/pcs-onboarding.md.
cmd_reset() {
    [ "${1:-}" = "--confirm" ] \
        || error "reset disables every local account on this PCS; pass --confirm if that is what you want"

    local backup=""

    # Keep an undo. A box being reset for a test may still hold real accounts,
    # and users_database.yml is the only copy of their password hashes. The
    # backup is a sibling file, which is safe: Authelia reads the one path it is
    # configured with and never scans the directory.
    if [ -f "$USERS_DB" ]; then
        local stamp suffix=0
        stamp="$(date -u +%Y%m%dT%H%M%SZ)"
        # Second granularity collides when reset runs twice inside one second —
        # which is exactly what a test script does. Never clobber: the file being
        # overwritten could be the one holding the real accounts.
        backup="$USERS_DB.$stamp.reset-backup"
        while [ -e "$backup" ]; do
            suffix=$((suffix + 1))
            backup="$USERS_DB.$stamp-$suffix.reset-backup"
        done
        cp -a "$USERS_DB" "$backup" || error "could not back up $USERS_DB"
        rm -f "$USERS_DB"
    fi

    rm -f "$COMPLETED_MARKER"

    # Cleared BEFORE the re-seed: the mesh ensure-authelia.sh reads
    # LOCAL_ADMIN_USER to decide whose block to stamp the owner email onto, and a
    # stale value would re-seed the placeholder under the previous owner's name.
    # The .pcs.env copy is a pre-switch leftover; cleared too so nothing reads it.
    "$ENV_MGR" delete LOCAL_ADMIN_USER "$MESH_ENV" >/dev/null 2>&1 || true
    "$ENV_MGR" delete LOCAL_ADMIN_USER "$PCS_ENV" >/dev/null 2>&1 || true

    # Removing the file is what re-arms the seed: ensure-authelia.sh's one-shot
    # check is a pure "has this been written yet?" test on a `password:` field.
    # It restarts Authelia itself, so no separate restart here, and it withdraws
    # the Local Account connector's drop-in on the now-unclaimed account. Both
    # mesh scripts run under the mesh lock, so they never interleave with the
    # mesh cron.
    if ! mesh_run self-check/ensure-authelia.sh >/dev/null 2>&1; then
        error "ensure-authelia.sh failed${backup:+; previous users_database.yml kept at $backup}"
    fi

    # Then Dex re-renders now rather than at the next tick — an unclaimed PCS must
    # not advertise a login that cannot work. With no other connector left, Dex is
    # removed (it cannot run on none) and the gates show "sign-in unavailable".
    mesh_run self-check/ensure-dex.sh >/dev/null 2>&1 \
        || echo "WARNING: ensure-dex.sh failed; the Local Account connector goes away at the next mesh self-check" >&2

    # Maison needs no re-arming: it asks the admin app on every navigation, and the
    # admin app sees this box unclaimed again. (A box still on the legacy gate
    # re-gates at the next self-check.)

    if is_claimed; then
        error "reset failed: this PCS still reads as claimed${backup:+ (backup at $backup)}"
    fi

    B="$backup" yq -o=json -I=0 -n \
        '{"claimed": false, "completed": false, "username": "", "backup": strenv(B)}'
}

usage() {
    cat >&2 <<'EOF'
Usage:
  onboarding.sh status
  onboarding.sh run              # ONBOARDING_USERNAME=... ; password on stdin
  onboarding.sh mark-completed
  onboarding.sh reset --confirm  # unclaim, so the first-start wizard replays

Env for `run`:
  ONBOARDING_USERNAME   (required) login name chosen by the owner
  ONBOARDING_DISPLAYNAME(optional) defaults to "Administrator"
  ONBOARDING_GENERATE   (optional) "1" to mint a password instead of reading stdin
EOF
    exit 1
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift

case "$COMMAND" in
    status)         [ $# -eq 0 ] || usage; cmd_status ;;
    run)            [ $# -eq 0 ] || usage; cmd_run ;;
    mark-completed) [ $# -eq 0 ] || usage; cmd_mark_completed ;;
    reset)          [ $# -le 1 ] || usage; cmd_reset "$@" ;;
    *)              usage ;;
esac
