#!/bin/bash
# ensure-backup-credentials.sh - Fetch this box's scoped B2 backup credentials.
#
# Phase 1 of the backup design (BACKUP-STORAGE-PLAN.md §6 step 4). It exchanges the
# box's USER_JWT for a per-device, bucket- and prefix-restricted B2 application key
# and parks it as BACKUP_* in the kopia stack's own /DATA/AppData/kopia/.stack.env. It renders nothing and starts nothing:
# ensure-backup-config.sh turns these values into an engine configuration.
#
# MUST RUN AFTER ensure-yundera-user-data.sh, which supplies (and rotates) USER_JWT
# and writes DOMAIN — the label this script sends. MUST RUN BEFORE
# ensure-backup-config.sh, which consumes what it writes.
#
# CALL SPARINGLY. The server is deliberately dumb: every call mints a fresh key and
# revokes this device's previous one, so a box that called nightly would churn keys
# against B2's rate limits and trip the server's per-device mint ceiling (429). The
# idempotency lives HERE — we call only when the credential is absent, within
# RENEW_WINDOW_DAYS of expiry, or when ensure-backup-config.sh left the refresh
# marker because the engine was refused by the storage. A healthy box lands on the
# route about four times a year.
#
# Enable/disable with BACKUP_ENABLED in .pcs.env (default: enabled). Set it to
# 0/false/no on a box that must not consume a backup space at all. The demo box is
# the case that motivated the knob: it is destroyed and rebuilt daily, and a rebuilt
# box arrives with no kopia .stack.env and therefore a fresh BACKUP_DEVICE_ID, so
# every rebuild mints a key that nothing ever revokes -- revocation is per-device and
# only ever kills the SAME device's previous key. At a 90-day TTL that accumulates
# roughly one live orphan key per day, against a space whose owner is the demo
# service's own account rather than a user who could ever restore from it.
#
# IT IS ALSO HOW A BOX LEARNS ITS SPACE WAS RESET. A user who has lost the encryption key
# resets the space from the Yundera dashboard: every key is revoked, the prefix is emptied,
# and the space answers with a new `resetAt`. This script records it as BACKUP_RESET_AT and
# acts on a change — see "the space was reset" below. A box stuck in needs-recovery calls
# on every run for exactly this reason; nothing else would tell it.
#
# FAILURE IS SOFT, ALWAYS. Backups are not load-bearing for a PCS booting, and this
# runs nightly on every box in the fleet: an orchestrator that is down, an older
# orchestrator with no such route, or a rate limit must all leave the existing
# credential alone and exit 0. A box with no credential simply reports "not
# configured" in Maison, which is the correct state for a box that was never
# provisioned a backup space.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"

# Kept in step with ensure-backup-config.sh, which drops the refresh marker here — now by
# sourcing the same definition rather than by restating the path and hoping they match.
# The library only sets values and defines one function; sourcing it has no side effects.
#
# This script runs BEFORE ensure-backup-config.sh, and that is the script which moves the
# engine directory here on a box that has not migrated yet. So on that one cycle the
# marker is looked for at a path that does not exist yet. Harmless and self-correcting:
# need_refresh() falls through to the key and expiry checks against the kopia
# .stack.env, which does not move, and the marker is read at the new path from the next cycle on.
source "$YND_TEMPLATE/scripts/library/kopia.sh"
# stack_env_set / stack_env_adopt.
source "$YND_TEMPLATE/scripts/library/env.sh"
ENGINE_DIR="$KOPIA_ENGINE_DIR"
# Where BACKUP_* lives: the kopia stack's own .stack.env (library/kopia.sh). USER_JWT
# and DOMAIN, the inputs, stay in the hand-off files.
STACK_ENV="$KOPIA_STACK_ENV"
REFRESH_MARKER="$ENGINE_DIR/needs-credentials"
# Written by ensure-backup-config.sh when the storage holds a repository this box has no
# password for; cleared here when the space has been reset since.
RECOVERY_MARKER="$ENGINE_DIR/needs-recovery"

# The key's TTL is 90 days server-side. Renewing at 30 days left gives a box that is
# switched off for a month, or whose nightly self-check has been failing, three
# chances to catch up before its backups start failing.
RENEW_WINDOW_DAYS=30

env_get() { "$ENV_MGR" get "$1" "$2" 2>/dev/null || echo ""; }

# Before anything reads BACKUP_*, and before the BACKUP_ENABLED gate, so a disabled box
# moves them too: an older template kept them in .pcs.secret.env.
kopia_adopt_backup_env

# --- is it wanted here? ------------------------------------------------------
#
# Checked before anything else, so a disabled box never reaches the mint call and
# never writes a BACKUP_* value that ensure-backup-config.sh would then act on.
# Absent means enabled: the fleet has no such line today and must keep its backups.
ENABLED="$(env_get BACKUP_ENABLED "$PCS_ENV")"
case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
        log_info "Backups disabled by BACKUP_ENABLED in .pcs.env - not fetching credentials"
        exit 0
        ;;
esac

# --- preconditions -----------------------------------------------------------

if [ ! -f "$SECRET_ENV" ]; then
    log_warn "No $SECRET_ENV - skipping backup credentials"
    exit 0
fi

USER_JWT="$(env_get USER_JWT "$SECRET_ENV")"
if [ -z "$USER_JWT" ]; then
    # An unclaimed box, or one whose user data has never been fetched. Not an error.
    log_info "No USER_JWT yet - skipping backup credentials"
    exit 0
fi

OPERATOR_API="$(env_get OPERATOR_API "$PCS_ENV")"
if [ -z "$OPERATOR_API" ]; then
    OPERATOR_API="https://app.yundera.com/service/pcs"
fi

# --- device identity ---------------------------------------------------------
#
# Generated once and never again. It is the key's name server-side, it is what the
# server revokes against, and ensure-backup-config.sh pins it as kopia's hostname —
# the identity every snapshot is filed under. Regenerating it would orphan this box's
# entire backup history, so it is minted here and treated as immutable afterwards.
#
# 32 lowercase hex characters, inside the server's 8-64 hex contract.
BACKUP_DEVICE_ID="$(env_get BACKUP_DEVICE_ID "$STACK_ENV")"
if [ -z "$BACKUP_DEVICE_ID" ]; then
    BACKUP_DEVICE_ID="$(openssl rand -hex 16)"
    stack_env_set BACKUP_DEVICE_ID         "$BACKUP_DEVICE_ID"  "$STACK_ENV"
    log_info "Minted BACKUP_DEVICE_ID for this box"
fi

# --- do we need to call at all? ----------------------------------------------

need_refresh() {
    # A box in recovery asks on EVERY run. It is the one way it learns that the user reset
    # the space from the dashboard (resetAt, below); without it a stuck box stays stuck
    # until an operator steps in, which is the situation the reset exists to end. The cost
    # is one mint per self-check, well inside the server's ceiling of ten per device per
    # UTC day, and only on a box that is taking no backups anyway.
    if [ -f "$RECOVERY_MARKER" ]; then
        log_info "Box is in backup recovery - asking whether the space was reset"
        return 0
    fi

    if [ -f "$REFRESH_MARKER" ]; then
        log_info "Refresh marker present - the engine was refused by the storage"
        return 0
    fi

    local key expires_at expires_epoch now_epoch
    key="$(env_get BACKUP_ACCESS_KEY_ID "$STACK_ENV")"
    if [ -z "$key" ]; then
        log_info "No backup credential on this box yet"
        return 0
    fi

    expires_at="$(env_get BACKUP_EXPIRES_AT "$STACK_ENV")"
    if [ -z "$expires_at" ]; then
        log_info "Backup credential has no recorded expiry - refreshing"
        return 0
    fi

    # An unparseable date is treated as expired rather than ignored: the failure mode
    # of refreshing too eagerly is one extra key mint, and of never refreshing is a
    # box that silently stops backing up in 90 days.
    if ! expires_epoch="$(date -d "$expires_at" +%s 2>/dev/null)"; then
        log_warn "Unparseable BACKUP_EXPIRES_AT ($expires_at) - refreshing"
        return 0
    fi
    now_epoch="$(date +%s)"
    if [ "$((expires_epoch - now_epoch))" -lt "$((RENEW_WINDOW_DAYS * 86400))" ]; then
        log_info "Backup credential expires $expires_at - inside the renewal window"
        return 0
    fi

    return 1
}

if ! need_refresh; then
    log_success "Backup credential is current - no call needed"
    exit 0
fi

# --- fetch -------------------------------------------------------------------
#
# label is display-only server-side, capped and sanitised there; sending the domain
# is what makes the admin view of a user's attached devices readable.
LABEL="$(env_get DOMAIN "$USER_ENV")"

URL="${OPERATOR_API}/user/backup/space?deviceId=${BACKUP_DEVICE_ID}"
if [ -n "$LABEL" ]; then
    URL="${URL}&label=$(printf '%s' "$LABEL" | sed 's/[^A-Za-z0-9._-]/-/g')"
fi

RESPONSE="$(curl -s -m 60 -w "HTTPSTATUS:%{http_code}" \
    -H "Authorization: Bearer $USER_JWT" \
    -H "Content-Type: application/json" \
    -X GET "$URL" || echo "HTTPSTATUS:000")"

HTTP_CODE="$(echo "$RESPONSE" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)"
BODY="$(echo "$RESPONSE" | sed -E 's/HTTPSTATUS:[0-9]*$//')"

case "$HTTP_CODE" in
    200) ;;
    404|501)
        # An orchestrator that predates the route. Nothing is wrong with this box.
        log_info "Backup space API not available on $OPERATOR_API - skipping"
        exit 0
        ;;
    409)
        # SPACE_RESETTING: the user started a reset from the dashboard and it has not
        # finished — keys are being revoked and the prefix emptied. The server refuses to
        # mint until it is done, so a box cannot get a writable key between the revoke and
        # the wipe. Nothing to do but wait; the next cycle picks up resetAt.
        if printf '%s' "$BODY" | grep -q 'SPACE_RESETTING'; then
            log_warn "Backup space is being reset from the dashboard - keeping the current credential, retrying next cycle"
        else
            log_warn "Backup space API returned HTTP 409 - keeping the current credential ($BODY)"
        fi
        exit 0
        ;;
    429)
        # The per-device mint ceiling. Whatever credential we hold is still valid;
        # hammering it is exactly what the ceiling exists to stop.
        log_warn "Backup space API rate-limited this device - keeping the current credential"
        exit 0
        ;;
    *)
        log_warn "Backup space API returned HTTP $HTTP_CODE - keeping the current credential ($BODY)"
        exit 0
        ;;
esac

json_str() { echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed "s/\"$2\":\"\([^\"]*\)\"/\1/" || echo ""; }
json_bool() { echo "$1" | grep -o "\"$2\":\(true\|false\)" | head -1 | sed "s/\"$2\"://" || echo ""; }

SPACE_ID="$(json_str "$BODY" spaceId)"
ENDPOINT="$(json_str "$BODY" endpoint)"
REGION="$(json_str "$BODY" region)"
BUCKET="$(json_str "$BODY" bucket)"
PREFIX="$(json_str "$BODY" prefix)"
ACCESS_KEY_ID="$(json_str "$BODY" accessKeyId)"
SECRET_ACCESS_KEY="$(json_str "$BODY" secretAccessKey)"
EXPIRES_AT="$(json_str "$BODY" expiresAt)"
STATUS="$(json_str "$BODY" status)"
WRITABLE="$(json_bool "$BODY" writable)"
# Absent until the space is first reset (the server omits it rather than sending null).
RESET_AT="$(json_str "$BODY" resetAt)"

if [ -z "$BUCKET" ] || [ -z "$PREFIX" ] || [ -z "$ACCESS_KEY_ID" ] || [ -z "$SECRET_ACCESS_KEY" ]; then
    log_warn "Backup space response was missing required fields - keeping the current credential"
    exit 0
fi

# The trailing slash is load-bearing: B2 matches namePrefix as a raw string, so a key
# scoped to s/space0 also opens s/space01/ — a live cross-tenant read, confirmed
# against B2 during the design spike. The server enforces this when it writes the
# space record; refusing it again here means a server-side regression cannot reach
# storage through this box.
case "$PREFIX" in
    */) ;;
    *)
        log_error "Refusing a backup prefix without a trailing slash: $PREFIX"
        exit 1
        ;;
esac

# --- the space was reset -----------------------------------------------------
#
# A reset from the dashboard has emptied the prefix: whatever repository lived there is
# gone, along with every snapshot, and the server now reports when that happened. What
# that means for THIS box depends on where it stands, and the comparison is made against
# what it knew BEFORE this response — BACKUP_RESET_AT is only written further down, once
# everything here has been parsed and checked.
#
#   - IN needs-recovery, with resetAt newer than the marker's detectedAt: the repository
#     this box could not open is the one that was erased. Remove the marker;
#     ensure-backup-config.sh runs next, mints a password and creates a fresh repository,
#     and Maison mails the new key. A resetAt OLDER than the marker means the box hit a
#     repository created after that reset — another box's, live — and it stays put.
#
#   - NOT in recovery, with a recorded BACKUP_RESET_AT that differs: this box had a
#     working repository and it was erased under it (two boxes on one space, the user
#     resetting from the other's trouble). Its repository.config and repository.password
#     now describe nothing, and kept in place they would make ensure-backup-config.sh
#     take the steady-state branch and fail `status` forever. Move both aside — renamed,
#     never deleted: the password is the one thing that could still read a repository if
#     this reading of events were ever wrong — and let config create.
#
#   - NOTHING RECORDED YET: only record. A box upgrading onto this template must never act
#     on a reset it did not live through: its repository may well have been created after
#     that reset, and moving its password aside would orphan every snapshot since.
#
# Dates are compared as epochs; anything unparseable is logged and NOT acted on. The
# failure mode of hesitating is one more night in the current state, and of acting
# wrongly is a box that abandons its own repository.
STORED_RESET_AT="$(env_get BACKUP_RESET_AT "$STACK_ENV")"
if [ -n "$RESET_AT" ]; then
    if [ -f "$RECOVERY_MARKER" ]; then
        # Not json_str: ensure-backup-config.sh writes the marker pretty-printed, with a
        # space after each colon, which the API parser's pattern does not allow for.
        DETECTED_AT="$(sed -n 's/.*"detectedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RECOVERY_MARKER" 2>/dev/null | head -n1 || true)"
        if ! reset_epoch="$(date -d "$RESET_AT" +%s 2>/dev/null)"; then
            log_warn "Unparseable resetAt ($RESET_AT) - leaving the recovery marker in place"
        # Empty is checked first: `date -d ""` succeeds, as today's midnight.
        elif [ -z "$DETECTED_AT" ] || ! detected_epoch="$(date -d "$DETECTED_AT" +%s 2>/dev/null)"; then
            log_warn "Recovery marker has no readable detectedAt ($DETECTED_AT) - leaving it in place"
        elif [ "$reset_epoch" -gt "$detected_epoch" ]; then
            rm -f "$RECOVERY_MARKER"
            log_info "Backup space was reset at $RESET_AT, after recovery was flagged at $DETECTED_AT - cleared needs-recovery, a fresh repository is created next"
        fi
    elif [ -n "$STORED_RESET_AT" ] && [ "$STORED_RESET_AT" != "$RESET_AT" ]; then
        STAMP="$(date +%Y%m%d%H%M%S)"
        for f in "$ENGINE_DIR/repository.config" "$ENGINE_DIR/repository.password"; do
            if [ -e "$f" ]; then
                mv -f "$f" "$f.reset-$STAMP"
                log_info "Backup space was reset at $RESET_AT - moved $(basename "$f") aside to $(basename "$f").reset-$STAMP"
            fi
        done
    fi
fi

stack_env_set BACKUP_SPACE_ID          "$SPACE_ID"          "$STACK_ENV"
stack_env_set BACKUP_ENDPOINT          "$ENDPOINT"          "$STACK_ENV"
stack_env_set BACKUP_REGION            "$REGION"            "$STACK_ENV"
stack_env_set BACKUP_BUCKET            "$BUCKET"            "$STACK_ENV"
stack_env_set BACKUP_PREFIX            "$PREFIX"            "$STACK_ENV"
stack_env_set BACKUP_ACCESS_KEY_ID     "$ACCESS_KEY_ID"     "$STACK_ENV"
stack_env_set BACKUP_SECRET_ACCESS_KEY "$SECRET_ACCESS_KEY" "$STACK_ENV"
stack_env_set BACKUP_EXPIRES_AT        "$EXPIRES_AT"        "$STACK_ENV"
stack_env_set BACKUP_STATUS            "${STATUS:-ok}"      "$STACK_ENV"
stack_env_set BACKUP_WRITABLE          "${WRITABLE:-true}"  "$STACK_ENV"
# Only when the server sent one: a response without it (never reset, or an older
# orchestrator) must not erase a value this box has already recorded.
if [ -n "$RESET_AT" ]; then
    stack_env_set BACKUP_RESET_AT      "$RESET_AT"          "$STACK_ENV"
fi

chmod 600 "$STACK_ENV"
rm -f "$REFRESH_MARKER"

log_success "Backup credential refreshed (space $SPACE_ID, expires $EXPIRES_AT, writable ${WRITABLE:-true})"
