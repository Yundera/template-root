#!/bin/bash
# backup.sh - The backup half of onboarding: state, on/off, the owner's password.
#
# The admin app's backup slide calls this, the way its account slide calls
# onboarding.sh. Like that file, it is the host's side of the contract: what "turn
# backups on" or "start over" means on this box is decided here, against the
# self-check scripts that own the engine directory, not in the product.
#
# Usage:
#   backup.sh status            -> JSON state, safe to poll
#   backup.sh enable | disable  -> set BACKUP_ENABLED in .pcs.env and reconcile now
#   backup.sh init              -> create the repository with the password on stdin
#   backup.sh recover           -> reattach to the existing repository, key on stdin
#   backup.sh reset --confirm   -> erase the backup space and start over (needs-recovery)
#
# STDOUT IS A MACHINE INTERFACE. Every subcommand prints the status JSON and nothing
# else; diagnostics go to stderr and a non-zero exit carries the reason (`ERROR: …`).
# Same contract as onboarding.sh, so the admin app parses both with one helper.
#
#   {"enabled":bool,"state":"needs-secret|needs-recovery|ready|disabled|unavailable",
#    "engine":"kopia","spaceId":"…"}
#
#   disabled        BACKUP_ENABLED is off in .pcs.env (the owner's explicit choice)
#   ready           the engine has a repository.config: every box set up before
#                   2026-10-16, and every box whose owner has chosen a password since
#   needs-recovery  the space holds a repository and this box has no password
#                   (rebuilt / re-created box): recover with the old one, or reset
#   needs-secret    the space is empty and the owner has not chosen a password yet
#   unavailable     none of the above: no backup credential yet, or the storage could
#                   not be probed. ensure-backup-config.sh retries every self-check.
#
# Read from files, never by asking Maison, like ensure-kopia-stack.sh: the answer must
# not depend on the dashboard being up.
#
# WHY THE PASSWORD IS ON STDIN. The admin app reaches the host through a one-shot
# container whose argv and environment are visible in `ps` on the host (see
# onboarding.sh). The password is read here with `IFS= read -r` (one line, spaces kept)
# and handed to `maison backup init|recover` on ITS stdin through `docker exec -i`, so it
# is in no argv and no environment on any hop. Maison writes it to the engine's
# protocol file (repository.password.initial / .candidate) and the engine removes that
# file on every path.
#
# init and recover go THROUGH MAISON rather than straight to the engine so that Maison
# records what it must: the key held by the user, the secret incident resolved, the
# engine rescanned. A Maison older than 1.1.64 has no `backup init`; the verb then fails
# with that reason.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"
YND_TEMPLATE="$YND_ROOT/template"

PCS_ENV="$YND_ROOT/.pcs.env"
SECRET_ENV="$YND_ROOT/.pcs.secret.env"
ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"
SELF_CHECK="$YND_TEMPLATE/scripts/self-check"

# ENGINE_ID, KOPIA_ENGINE_DIR, KOPIA_STACK_ENV. Sets values only; no log output, which
# matters here: stdout is JSON.
source "$YND_TEMPLATE/scripts/library/kopia.sh"

CONFIG_FILE="$KOPIA_ENGINE_DIR/repository.config"
RECOVERY_MARKER="$KOPIA_ENGINE_DIR/needs-recovery"
SECRET_MARKER="$KOPIA_ENGINE_DIR/needs-secret"
REFRESH_MARKER="$KOPIA_ENGINE_DIR/needs-credentials"
STATE_FILE="$KOPIA_ENGINE_DIR/state.json"

# How long `reset` waits for the orchestrator to finish erasing the space. The route
# answers 202 and erases in the background; the credential API refuses (409) until it is
# done. Kept under the admin app's host-verb timeout. Past it the box is left in
# needs-recovery and the next self-check finishes the job.
RESET_WAIT="${BACKUP_RESET_WAIT:-150}"
RESET_POLL=10

error() {
    echo "ERROR: $1" >&2
    exit 1
}

warn() {
    echo "WARNING: $1" >&2
}

command -v yq >/dev/null 2>&1 || error "yq not found (installed by self-check/ensure-common-tools-installed.sh)"

env_get() { "$ENV_MGR" get "$1" "$2" 2>/dev/null || true; }

# A self-check script, run now rather than at the next tick. Its log lines go to
# stderr (stdout is ours), and its failure is a warning: the status that follows
# reports the state it left, which is the answer the caller needs.
run_check() {
    local script="$1"
    if [ ! -f "$SELF_CHECK/$script" ]; then
        warn "$script not found"
        return 0
    fi
    bash "$SELF_CHECK/$script" >&2 || warn "$script exited $?"
}

backup_enabled() {
    case "$(env_get BACKUP_ENABLED "$PCS_ENV" | tr '[:upper:]' '[:lower:]')" in
        0|false|no|off) return 1 ;;
    esac
    return 0
}

current_state() {
    if ! backup_enabled; then
        echo disabled
    elif [ -f "$CONFIG_FILE" ]; then
        echo ready
    elif [ -f "$RECOVERY_MARKER" ]; then
        echo needs-recovery
    elif [ -f "$SECRET_MARKER" ]; then
        echo needs-secret
    else
        echo unavailable
    fi
}

space_id() {
    local id
    id="$(env_get BACKUP_SPACE_ID "$KOPIA_STACK_ENV")"
    # A box an older template provisioned may still carry BACKUP_* in .pcs.secret.env
    # until a backup self-check adopts it; state.json has the id either way.
    if [ -z "$id" ] && [ -r "$STATE_FILE" ]; then
        id="$(yq -p=json -r '.spaceId // ""' "$STATE_FILE" 2>/dev/null || true)"
    fi
    printf '%s' "$id"
}

cmd_status() {
    local enabled="true" state
    backup_enabled || enabled="false"
    state="$(current_state)"
    E="$enabled" S="$state" G="$ENGINE_ID" P="$(space_id)" yq -o=json -I=0 -n \
        '{"enabled": (strenv(E) == "true"), "state": strenv(S), "engine": strenv(G), "spaceId": strenv(P)}'
}

# enable | disable. The knob the three backup self-checks already read; running them
# now is what makes the switch take effect before the slide moves on: on enable a box
# fetches its credential (it may never have had one), probes its storage and starts
# the engine; on disable the kopia stack comes down. Disabling destroys nothing — the
# repository and its password stay on disk (see ensure-backup-config.sh).
cmd_switch() {
    local value="$1"
    "$ENV_MGR" set BACKUP_ENABLED "$value" "$PCS_ENV" >/dev/null \
        || error "could not set BACKUP_ENABLED in $PCS_ENV"
    run_check ensure-backup-credentials.sh
    run_check ensure-backup-config.sh
    run_check ensure-kopia-stack.sh
    cmd_status
}

# init | recover. One line of stdin, handed on to Maison's CLI on its stdin. Maison
# answers wrong_key / repository_exists / not_awaiting_secret / too_short in brackets on
# stderr; that message is passed through as the ERROR so the slide can tell them apart.
cmd_secret() {
    local verb="$1" plaintext="" out

    backup_enabled || error "backups are disabled on this PCS; enable them first"

    docker exec maison-app maison help 2>/dev/null | grep -q "backup $verb" \
        || error "this Maison has no 'backup $verb' (Maison 1.1.64 or later is required), or it is not running"

    IFS= read -r plaintext || true
    [ -n "$plaintext" ] || error "no password on stdin"

    if ! out="$(printf '%s\n' "$plaintext" \
        | docker exec -i maison-app maison backup "$verb" "$ENGINE_ID" 2>&1 >/dev/null)"; then
        unset plaintext
        error "${out:-maison backup $verb failed}"
    fi
    unset plaintext

    # The repository exists now (init) or is reattached (recover): bring the UI up
    # beside the engine at once instead of at the next self-check.
    run_check ensure-kopia-stack.sh
    cmd_status
}

# reset --confirm: "start over" for a box in needs-recovery whose owner has lost the
# password. The orchestrator erases the space (every snapshot under the prefix) and
# revokes its keys; ensure-backup-credentials.sh then sees the new resetAt and clears
# needs-recovery, and ensure-backup-config.sh probes an empty space: needs-secret.
#
# The box's own USER_JWT authorises it, for this box's own space only, and the body
# must name that space ({"confirm": spaceId}). The orchestrator rate-limits it.
#
# REFUSED IN EVERY OTHER STATE. On a ready box this would erase working backups, which
# no slide offers; the dashboard is the place for that decision.
cmd_reset() {
    [ "${1:-}" = "--confirm" ] \
        || error "reset erases every backup in this PCS's backup space; pass --confirm if that is what you want"

    local state
    state="$(current_state)"
    [ "$state" = "needs-recovery" ] \
        || error "reset is only for a PCS whose backups need recovery (current state: $state)"

    local user_jwt operator_api space body header_file response http_code resp_body code msg
    [ -r "$SECRET_ENV" ] || error "no $SECRET_ENV"
    user_jwt="$(env_get USER_JWT "$SECRET_ENV")"
    [ -n "$user_jwt" ] || error "no USER_JWT on this PCS yet"
    operator_api="$(env_get OPERATOR_API "$PCS_ENV")"
    operator_api="${operator_api:-https://app.yundera.com/service/pcs}"
    space="$(space_id)"
    [ -n "$space" ] || error "no backup space id on this PCS"

    body="$(S="$space" yq -o=json -I=0 -n '{"confirm": strenv(S)}')"

    # The bearer goes through a 0600 header file, not curl's argv.
    header_file="$(mktemp)"
    chmod 600 "$header_file"
    # shellcheck disable=SC2064 # expand now: the path is local
    trap "rm -f '$header_file'" EXIT
    printf 'Authorization: Bearer %s\n' "$user_jwt" > "$header_file"
    unset user_jwt

    response="$(curl -s -m 60 -w "HTTPSTATUS:%{http_code}" \
        -H "@$header_file" \
        -H "Content-Type: application/json" \
        -X POST --data "$body" \
        "$operator_api/user/backup/reset" || echo "HTTPSTATUS:000")"
    rm -f "$header_file"

    http_code="$(printf '%s' "$response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)"
    resp_body="$(printf '%s' "$response" | sed -E 's/HTTPSTATUS:[0-9]*$//')"

    # The orchestrator's error code leads the message ("ERROR: <CODE>: …") so the admin
    # app can map it: CONFIRM_REQUIRED / CONFIRM_MISMATCH (400), NO_BACKUP_SPACE (404),
    # a reset already running or the space queued for erasure (409), RESET_RATE_LIMIT
    # (429, three a day per account).
    code="$(printf '%s' "$resp_body" | yq -p=json -r '.error // ""' 2>/dev/null || true)"
    msg="$(printf '%s' "$resp_body" | yq -p=json -r '.message // ""' 2>/dev/null || true)"
    case "$http_code" in
        200|202) ;;
        000) error "UNREACHABLE: could not reach $operator_api" ;;
        400) error "${code:-BAD_REQUEST}: ${msg:-the orchestrator refused the reset request}" ;;
        401|403) error "${code:-UNAUTHORIZED}: the orchestrator refused this PCS's identity for a reset (HTTP $http_code)" ;;
        404) error "${code:-NOT_FOUND}: ${msg:-no backup space to reset, or the orchestrator has no such route}" ;;
        409) error "${code:-CONFLICT}: ${msg:-the backup space cannot be reset right now}" ;;
        429) error "${code:-RESET_RATE_LIMIT}: ${msg:-too many resets today for this account; try again tomorrow}" ;;
        *)   error "${code:-HTTP_$http_code}: ${msg:-reset failed (HTTP $http_code)}" ;;
    esac

    # The erase runs in the background on the orchestrator; until it finishes the
    # credential API answers SPACE_RESETTING and nothing changes here. A box in recovery
    # asks it on every run (ensure-backup-credentials.sh), so asking again is all the
    # polling there is. The refresh marker makes it ask even if that ever changes.
    local deadline=$((SECONDS + RESET_WAIT))
    while :; do
        touch "$REFRESH_MARKER" 2>/dev/null || true
        run_check ensure-backup-credentials.sh
        [ -f "$RECOVERY_MARKER" ] || break
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep "$RESET_POLL"
    done

    if [ -f "$RECOVERY_MARKER" ]; then
        warn "the backup space is still being erased; this PCS picks the reset up at its next self-check"
    fi
    run_check ensure-backup-config.sh
    run_check ensure-kopia-stack.sh
    cmd_status
}

usage() {
    cat >&2 <<'EOF'
Usage:
  backup.sh status
  backup.sh enable
  backup.sh disable
  backup.sh init             # the new repository password on stdin (one line)
  backup.sh recover          # the existing repository password on stdin (one line)
  backup.sh reset --confirm  # erase the backup space and start over (needs-recovery only)
EOF
    exit 1
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift

case "$COMMAND" in
    status)  [ $# -eq 0 ] || usage; cmd_status ;;
    enable)  [ $# -eq 0 ] || usage; cmd_switch true ;;
    disable) [ $# -eq 0 ] || usage; cmd_switch false ;;
    init)    [ $# -eq 0 ] || usage; cmd_secret init ;;
    recover) [ $# -eq 0 ] || usage; cmd_secret recover ;;
    reset)   [ $# -le 1 ] || usage; cmd_reset "$@" ;;
    *)       usage ;;
esac
