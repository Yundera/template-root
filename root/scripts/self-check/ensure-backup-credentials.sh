#!/bin/bash
# ensure-backup-credentials.sh - Fetch this box's scoped B2 backup credentials.
#
# Phase 1 of the backup design (BACKUP-STORAGE-PLAN.md §6 step 4). It exchanges the
# box's USER_JWT for a per-device, bucket- and prefix-restricted B2 application key
# and parks it in .pcs.secret.env as BACKUP_*. It renders nothing and starts nothing:
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
# box arrives with a fresh .pcs.secret.env and therefore a fresh BACKUP_DEVICE_ID, so
# every rebuild mints a key that nothing ever revokes -- revocation is per-device and
# only ever kills the SAME device's previous key. At a 90-day TTL that accumulates
# roughly one live orphan key per day, against a space whose owner is the demo
# service's own account rather than a user who could ever restore from it.
#
# FAILURE IS SOFT, ALWAYS. Backups are not load-bearing for a PCS booting, and this
# runs nightly on every box in the fleet: an orchestrator that is down, an older
# orchestrator with no such route, or a rate limit must all leave the existing
# credential alone and exit 0. A box with no credential simply reports "not
# configured" in Maison, which is the correct state for a box that was never
# provisioned a backup space.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

# Kept in step with ensure-backup-config.sh, which drops the refresh marker here.
ENGINE_DIR="/DATA/AppDataShared/backup/kopia"
REFRESH_MARKER="$ENGINE_DIR/needs-credentials"

# The key's TTL is 90 days server-side. Renewing at 30 days left gives a box that is
# switched off for a month, or whose nightly self-check has been failing, three
# chances to catch up before its backups start failing.
RENEW_WINDOW_DAYS=30

env_get() { "$ENV_MGR" get "$1" "$2" 2>/dev/null || echo ""; }

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
    OPERATOR_API="$(env_get YUNDERA_API "$PCS_ENV")"   # pre-rename name
fi
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
BACKUP_DEVICE_ID="$(env_get BACKUP_DEVICE_ID "$SECRET_ENV")"
if [ -z "$BACKUP_DEVICE_ID" ]; then
    BACKUP_DEVICE_ID="$(openssl rand -hex 16)"
    "$ENV_MGR" set BACKUP_DEVICE_ID "$BACKUP_DEVICE_ID" "$SECRET_ENV"
    log_info "Minted BACKUP_DEVICE_ID for this box"
fi

# --- do we need to call at all? ----------------------------------------------

need_refresh() {
    if [ -f "$REFRESH_MARKER" ]; then
        log_info "Refresh marker present - the engine was refused by the storage"
        return 0
    fi

    local key expires_at expires_epoch now_epoch
    key="$(env_get BACKUP_ACCESS_KEY_ID "$SECRET_ENV")"
    if [ -z "$key" ]; then
        log_info "No backup credential on this box yet"
        return 0
    fi

    expires_at="$(env_get BACKUP_EXPIRES_AT "$SECRET_ENV")"
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

"$ENV_MGR" set BACKUP_SPACE_ID          "$SPACE_ID"          "$SECRET_ENV"
"$ENV_MGR" set BACKUP_ENDPOINT          "$ENDPOINT"          "$SECRET_ENV"
"$ENV_MGR" set BACKUP_REGION            "$REGION"            "$SECRET_ENV"
"$ENV_MGR" set BACKUP_BUCKET            "$BUCKET"            "$SECRET_ENV"
"$ENV_MGR" set BACKUP_PREFIX            "$PREFIX"            "$SECRET_ENV"
"$ENV_MGR" set BACKUP_ACCESS_KEY_ID     "$ACCESS_KEY_ID"     "$SECRET_ENV"
"$ENV_MGR" set BACKUP_SECRET_ACCESS_KEY "$SECRET_ACCESS_KEY" "$SECRET_ENV"
"$ENV_MGR" set BACKUP_EXPIRES_AT        "$EXPIRES_AT"        "$SECRET_ENV"
"$ENV_MGR" set BACKUP_STATUS            "${STATUS:-ok}"      "$SECRET_ENV"
"$ENV_MGR" set BACKUP_WRITABLE          "${WRITABLE:-true}"  "$SECRET_ENV"

chmod 600 "$SECRET_ENV"
rm -f "$REFRESH_MARKER"

log_success "Backup credential refreshed (space $SPACE_ID, expires $EXPIRES_AT, writable ${WRITABLE:-true})"
