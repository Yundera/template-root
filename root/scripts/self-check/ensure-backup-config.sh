#!/bin/bash
# ensure-backup-config.sh - Turn the BACKUP_* credentials into a connected kopia
# repository that Maison can use.
#
# Phase 1 step 4b (BACKUP-STORAGE-PLAN.md §6, §14). Infra generates, Maison consumes:
# this script owns the repository password, the repository configuration and the
# storage credentials; Maison reads what it finds under
# /DATA/AppDataShared/backup/kopia/ and shells out to the engine. Maison never sees
# the JWT, never talks to the backup space API, and never generates the password.
#
# MUST RUN AFTER ensure-backup-credentials.sh (which fetches BACKUP_*) and BEFORE
# ensure-maison-stack.sh, so a box that is being provisioned for the first time finds
# a connected repository on Maison's first boot instead of coming up "not configured"
# and waiting a day.
#
# VERSION-COUPLED: this requires a Maison image that passes AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY into the engine container (see "credentials" below). An older
# image finds a configuration whose credentials are blank and fails its backups until
# ensure-maison-stack.sh recreates the container with the pinned image, later in this
# same self-check cycle.
#
#
# WHY THE CREDENTIALS ARE NOT IN repository.config
# ------------------------------------------------
# `kopia repository connect` writes the S3 access key and secret into
# repository.config and there is no flag to stop it (--no-persist-credentials governs
# the repository *password*, not the storage credentials). We blank the two fields
# afterwards and hand kopia the credentials through the environment instead, which it
# accepts for every ordinary operation and does not write back.
#
# The reason is rotation. Keys expire every 90 days, and the alternative — re-running
# `repository connect` to install a new one — rewrites the whole configuration file,
# including the identity. A reconnect that omits --override-hostname/--override-username
# silently refiles the box under the engine container's random hostname and `root`
# (verified: hostname devicetest -> 4183fb3f384e, username pcs -> root). kopia keys
# snapshots user@host:path, so that costs a full re-hash of every file, and leaves
# per-source retention pointed at a lineage nothing writes to any more while the new
# one is covered by no policy at all. Maison lists with --all, so none of it is
# visible until the storage bill grows.
#
# So: repository.config is written exactly ONCE, and rotation rewrites nothing but
# credentials.env. Identity cannot drift because nothing touches the file again.
#
#
# THE REBUILT BOX
# ---------------
# A box that has lost its disk arrives here with a backup space full of snapshots and
# no repository password — the only copy is the one the user was mailed. Generating a
# fresh password here would either fail to connect or, worse, initialise a SECOND
# repository under the same prefix and leave the real backups invisible. So the
# password is generated only as part of a successful `repository create`, and kopia
# refusing to create over existing data ("found existing data in storage location") is
# taken as the signal to stop and mark the box as needing recovery. Recovery mode
# itself is not built yet; the marker is the seam it will plug into.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

ENGINE="kopia"
ENGINE_DIR="/DATA/AppDataShared/backup/$ENGINE"
CONFIG_FILE="$ENGINE_DIR/repository.config"
PASSWORD_FILE="$ENGINE_DIR/repository.password"
CREDENTIALS_FILE="$ENGINE_DIR/credentials.env"
STATE_FILE="$ENGINE_DIR/state.json"
REFRESH_MARKER="$ENGINE_DIR/needs-credentials"
RECOVERY_MARKER="$ENGINE_DIR/needs-recovery"

# MUST match kopia.DefaultImage in Maison. Two sides running different engine builds
# against one repository is how a format surprise becomes a 3am failure.
KOPIA_IMAGE="kopia/kopia:0.23.1"

env_get() { "$ENV_MGR" get "$1" "$2" 2>/dev/null || echo ""; }

# --- is this box provisioned for backups at all? ------------------------------

if [ ! -f "$SECRET_ENV" ]; then
    log_info "No $SECRET_ENV - nothing to configure"
    exit 0
fi

BACKUP_BUCKET="$(env_get BACKUP_BUCKET "$SECRET_ENV")"
BACKUP_PREFIX="$(env_get BACKUP_PREFIX "$SECRET_ENV")"
BACKUP_ENDPOINT="$(env_get BACKUP_ENDPOINT "$SECRET_ENV")"
BACKUP_REGION="$(env_get BACKUP_REGION "$SECRET_ENV")"
BACKUP_DEVICE_ID="$(env_get BACKUP_DEVICE_ID "$SECRET_ENV")"
ACCESS_KEY_ID="$(env_get BACKUP_ACCESS_KEY_ID "$SECRET_ENV")"
SECRET_ACCESS_KEY="$(env_get BACKUP_SECRET_ACCESS_KEY "$SECRET_ENV")"
BACKUP_WRITABLE="$(env_get BACKUP_WRITABLE "$SECRET_ENV")"
BACKUP_STATUS="$(env_get BACKUP_STATUS "$SECRET_ENV")"
BACKUP_SPACE_ID="$(env_get BACKUP_SPACE_ID "$SECRET_ENV")"
BACKUP_EXPIRES_AT="$(env_get BACKUP_EXPIRES_AT "$SECRET_ENV")"

if [ -z "$BACKUP_BUCKET" ] || [ -z "$ACCESS_KEY_ID" ] || [ -z "$SECRET_ACCESS_KEY" ]; then
    # The normal state of a box with no backup space. Maison shows "not configured".
    log_info "No backup credentials on this box - nothing to configure"
    exit 0
fi

case "$BACKUP_PREFIX" in
    */) ;;
    *)
        log_error "Refusing a backup prefix without a trailing slash: $BACKUP_PREFIX"
        exit 1
        ;;
esac

if [ -z "$BACKUP_DEVICE_ID" ]; then
    log_error "BACKUP_DEVICE_ID is missing - ensure-backup-credentials.sh must run first"
    exit 1
fi

if [ -f "$RECOVERY_MARKER" ]; then
    log_warn "This box is marked as needing backup recovery - not touching the repository"
    exit 0
fi

# --- directories --------------------------------------------------------------
#
# Maison runs the engine container as PUID:PGID, so everything here must be readable
# and writable by that uid rather than by root. cache/ and logs/ are excluded from the
# user-data backup set by pattern on Maison's side.
PUID="$(env_get PUID "$UNIFIED_ENV")"; PUID="${PUID:-1000}"
PGID="$(env_get PGID "$UNIFIED_ENV")"; PGID="${PGID:-1000}"

mkdir -p "$ENGINE_DIR/cache" "$ENGINE_DIR/logs"
# Not recursive: the cache is multi-gigabyte and turns over between runs, and this
# script runs nightly on every box. The directories are chowned so the engine can
# create files in them; each file this script writes is chowned individually below.
chown "$PUID:$PGID" /DATA/AppDataShared /DATA/AppDataShared/backup \
    "$ENGINE_DIR" "$ENGINE_DIR/cache" "$ENGINE_DIR/logs" 2>/dev/null || true
chmod 700 "$ENGINE_DIR"

# --- credentials.env ----------------------------------------------------------
#
# Rewritten on every rotation and read by Maison on every engine invocation. Written
# through a temporary and renamed, so a backup running at this moment reads either the
# whole old file or the whole new one — never half of each.
CRED_TMP="$(mktemp "$ENGINE_DIR/.credentials.XXXXXX")"
cat > "$CRED_TMP" <<EOF
# Generated by ensure-backup-config.sh - DO NOT EDIT.
# Storage credentials for the $ENGINE engine. Rotated roughly every 90 days.
AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY
EOF
chmod 600 "$CRED_TMP"
chown "$PUID:$PGID" "$CRED_TMP" 2>/dev/null || true
mv -f "$CRED_TMP" "$CREDENTIALS_FILE"

# --- state.json ---------------------------------------------------------------
#
# What Maison cannot learn from kopia. A suspended space connects and restores
# normally but refuses writes, and kopia reports that refusal as
# "unable to write session marker: BLOB not found" — which reads as "your backup is
# corrupt" to a user whose backups are in fact intact. Maison pre-checks this flag
# instead of interpreting the engine's error text.
# label is what the user sees in Maison instead of the engine's ID. It belongs here
# rather than in Maison because "kopia" is the engine while the label describes the
# SPACE it points at: a Yundera-provisioned PCS should say so, and a self-hoster
# running the same engine against their own bucket must not be told they are using a
# service they are not. BACKUP_LABEL overrides it if the credential API ever returns
# one per space.
BACKUP_LABEL="$(env_get BACKUP_LABEL "$SECRET_ENV")"
BACKUP_LABEL="${BACKUP_LABEL:-Yundera Backup Storage}"

cat > "$STATE_FILE" <<EOF
{
  "engine": "$ENGINE",
  "label": "$BACKUP_LABEL",
  "spaceId": "$BACKUP_SPACE_ID",
  "deviceId": "$BACKUP_DEVICE_ID",
  "writable": ${BACKUP_WRITABLE:-true},
  "status": "${BACKUP_STATUS:-ok}",
  "credentialExpiresAt": "$BACKUP_EXPIRES_AT"
}
EOF
chmod 644 "$STATE_FILE"
chown "$PUID:$PGID" "$STATE_FILE" 2>/dev/null || true

# --- engine invocation --------------------------------------------------------
#
# Secrets are passed by NAME (-e VAR), so their values never appear in argv and
# therefore never in another process's `ps`.
export AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY"

# KOPIA_CACHE_DIRECTORY and KOPIA_LOG_DIR are overridden by ENVIRONMENT, not by flag.
# The kopia image bakes KOPIA_CACHE_DIRECTORY=/app/cache and KOPIA_LOG_DIR=/app/logs
# into itself, and those outrank --cache-directory and --log-dir on the command line.
# /app belongs to root, so running as PUID the engine cannot create either and every
# command fails with "unable to create cache directory: mkdir /app/cache: permission
# denied" before it ever reaches the repository. Maison's engine runner overrides the
# same two variables for the same reason.
kopia_run() {
    docker run --rm \
        --user "$PUID:$PGID" \
        -v /DATA:/DATA \
        -e KOPIA_CACHE_DIRECTORY="$ENGINE_DIR/cache" \
        -e KOPIA_LOG_DIR="$ENGINE_DIR/logs" \
        -e KOPIA_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
        "$KOPIA_IMAGE" "$@" \
        --config-file="$CONFIG_FILE" 2>&1
}

# The storage arguments every create/connect shares. --override-hostname pins the
# identity to the device id: stable for the life of the box, unaffected by a domain
# change, and never re-derived. --cache-directory is a connect-time flag: kopia
# persists it into the configuration and rejects it on every other command.
# kopia's --endpoint is a host[:port], NOT a URL: given one it fails with "Endpoint url
# cannot have fully qualified paths". The credential API returns a URL on purpose —
# the contract is engine-independent and rclone, restic and the AWS SDK all want the
# scheme — so the conversion belongs here, in the one place that knows what kopia
# parses.
KOPIA_ENDPOINT="$BACKUP_ENDPOINT"
USE_TLS=1
case "$BACKUP_ENDPOINT" in
    https://*) KOPIA_ENDPOINT="${BACKUP_ENDPOINT#https://}" ;;
    http://*)  KOPIA_ENDPOINT="${BACKUP_ENDPOINT#http://}"; USE_TLS=0 ;;
esac
KOPIA_ENDPOINT="${KOPIA_ENDPOINT%/}"

STORAGE_ARGS=(
    "--bucket=$BACKUP_BUCKET"
    "--endpoint=$KOPIA_ENDPOINT"
    "--region=$BACKUP_REGION"
    "--prefix=$BACKUP_PREFIX"
    "--override-hostname=$BACKUP_DEVICE_ID"
    "--override-username=pcs"
)
if [ "$USE_TLS" = "0" ]; then
    # Only reachable with a local S3 (MinIO) standing in for the real space.
    STORAGE_ARGS+=("--disable-tls")
fi

# Blank the credentials kopia persisted, leaving the environment as their only source.
# Non-fatal: a kopia release that reformats its configuration leaves the credentials
# in place, which still works — it merely costs the rotation property this buys.
blank_persisted_credentials() {
    sed -i 's/"accessKeyID": *"[^"]*"/"accessKeyID": ""/; s/"secretAccessKey": *"[^"]*"/"secretAccessKey": ""/' \
        "$CONFIG_FILE" 2>/dev/null || true
    if grep -q "\"accessKeyID\": \"$ACCESS_KEY_ID\"" "$CONFIG_FILE" 2>/dev/null; then
        log_warn "Could not blank the persisted credentials in repository.config - rotation will need a reconnect"
    fi
}

# --- connect, or create once --------------------------------------------------

if [ -f "$CONFIG_FILE" ] && [ -f "$PASSWORD_FILE" ]; then
    # Steady state. The configuration is already correct and must not be rewritten;
    # rotation happened above when credentials.env was replaced. Prove the repository
    # is reachable and stop.
    export KOPIA_PASSWORD="$(cat "$PASSWORD_FILE")"
    if OUT="$(kopia_run repository status)"; then
        log_success "Backup repository is connected (space $BACKUP_SPACE_ID, writable ${BACKUP_WRITABLE:-true})"
        exit 0
    fi

    # Could not open the repository. Ask for a new credential on the next cycle.
    # ensure-backup-credentials.sh runs before this script, so the marker is consumed
    # on the next run, not in a few seconds.
    #
    # ANY failure arms the marker — deliberately, and NOT by matching the provider's
    # error text. This used to be gated on
    # `grep -qiE "access denied|invalidaccesskeyid|signature|expired"`, and B2's
    # wording for a REVOKED key is `The key '<id>' is not valid`, which matches none
    # of those four. A key deleted server-side therefore left the box holding a
    # credential that was "current" by expiry and dead in fact: no marker, this
    # script exiting 0, the self-check reporting green, and no backups at all until
    # the 30-day renewal window opened — about 60 days later. Observed on wisera,
    # 2026-08-20, while deliberately testing exactly this.
    #
    # The asymmetry is what settles it. A false positive (B2 briefly unreachable)
    # costs one extra /user/backup/space call, bounded by this script running once
    # per cycle and by the server's per-device mint ceiling of 10/UTC-day; the box
    # ends up with a working credential either way. A false negative costs months of
    # silent data loss. Matching error strings means every wording a provider
    # invents is a new silent outage, so the strings are gone.
    touch "$REFRESH_MARKER"
    chown "$PUID:$PGID" "$REFRESH_MARKER" 2>/dev/null || true
    log_warn "Backup repository unreachable - requesting a fresh credential on the next cycle: $(echo "$OUT" | tail -2)"
    exit 0
fi

if [ -f "$PASSWORD_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    # We hold the password but not the configuration — a restored password file, or a
    # configuration deleted by hand. Connecting is safe and does not initialise
    # anything.
    export KOPIA_PASSWORD="$(cat "$PASSWORD_FILE")"
    if OUT="$(kopia_run repository connect s3 "${STORAGE_ARGS[@]}")"; then
        blank_persisted_credentials
        chown "$PUID:$PGID" "$CONFIG_FILE" 2>/dev/null || true
        log_success "Reconnected the backup repository (space $BACKUP_SPACE_ID)"
        exit 0
    fi
    log_error "Could not connect the backup repository: $(echo "$OUT" | tail -2)"
    exit 1
fi

# No password on this box. Either the space is empty and we are the first box to
# attach, or this box was rebuilt and the password is only in the user's mailbox.
# `repository create` is what tells the two apart, so the password is held in memory
# until it succeeds and is written only then.
NEW_PASSWORD="$(openssl rand -base64 33 | tr -d '\n')"
export KOPIA_PASSWORD="$NEW_PASSWORD"

# THE PASSWORD IS WRITTEN BEFORE THE CREATE, NOT AFTER.
#
# `repository create` initialises the repository and then connects to it, and the
# second half can fail on its own — a cache directory it cannot write, a network blip.
# The format blob is already in storage at that point, encrypted with the password we
# are holding, so discarding it on failure abandons a repository nobody can ever open
# again AND leaves storage non-empty, which makes every later run mistake the debris
# for the user's real backups and refuse to touch the space forever.
#
# Writing first inverts the failure: the next run finds a password, takes the connect
# path, and finishes the job. The file is removed again only in the one case where we
# learn the repository was never ours.
umask 077
printf '%s' "$NEW_PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"
chown "$PUID:$PGID" "$PASSWORD_FILE" 2>/dev/null || true

if OUT="$(kopia_run repository create s3 "${STORAGE_ARGS[@]}")"; then
    blank_persisted_credentials
    chown "$PUID:$PGID" "$CONFIG_FILE" 2>/dev/null || true
    log_success "Created the backup repository for space $BACKUP_SPACE_ID"
    log_warn "The repository password exists ONLY on this box until the user is mailed a copy"
    exit 0
fi

if echo "$OUT" | grep -qi "found existing data"; then
    # Not our repository: the password we just minted opens nothing. Remove it, or the
    # next run takes the connect path and fails with "invalid password" instead of
    # reporting the recoverable truth.
    rm -f "$PASSWORD_FILE"
    # THE REBUILT BOX. Stop before doing damage.
    cat > "$RECOVERY_MARKER" <<EOF
{
  "reason": "repository-exists-without-password",
  "spaceId": "$BACKUP_SPACE_ID",
  "prefix": "$BACKUP_PREFIX",
  "detectedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 644 "$RECOVERY_MARKER"
    chown "$PUID:$PGID" "$RECOVERY_MARKER" 2>/dev/null || true
    log_error "Backup space $BACKUP_SPACE_ID already holds a repository and this box has no password."
    log_error "Not creating a second one. The user's emailed encryption key is required to recover."
    exit 0
fi

# Anything else: the repository may or may not have been initialised, and the password
# on disk is the only one that could open it if it was. Keep it and let the next run's
# connect path settle the question.
log_error "Could not create the backup repository: $(echo "$OUT" | tail -3)"
log_info "Keeping the generated password - the next cycle will try to connect with it"
exit 1
