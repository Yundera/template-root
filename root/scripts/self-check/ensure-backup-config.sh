#!/bin/bash
# ensure-backup-config.sh - Turn the BACKUP_* credentials into a connected backup
# repository that Maison can use, and declare the adapter that serves it.
#
# Phase 1 step 4b (BACKUP-STORAGE-PLAN.md §6, §14). Infra generates, Maison consumes:
# this script owns the repository password, the repository configuration, the storage
# credentials and the adapter descriptor; Maison reads what it finds under
# /DATA/AppDataShared/backup/kopia/ and runs the adapter. Maison never sees the JWT,
# never talks to the backup space API, and never generates the password.
#
# IT RUNS THE ADAPTER, NOT KOPIA. Every engine-specific step this used to carry — the
# create-or-connect dance, kopia's storage flag names, the endpoint URL that has to be
# reduced to a host[:port], the sed that blanks the credentials kopia persists into its
# own config — now lives behind `maison-engine connect`, in the image that ships the
# engine. What is left here is engine-neutral: fetch-time state, a generated password,
# two markers, and a descriptor naming the image.
#
# MUST RUN AFTER ensure-backup-credentials.sh (which fetches BACKUP_*) and BEFORE
# ensure-maison-stack.sh, so a box that is being provisioned for the first time finds
# a connected repository on Maison's first boot instead of coming up "not configured"
# and waiting a day.
#
# Enable/disable with BACKUP_ENABLED in .pcs.env (default: enabled), the same knob
# ensure-backup-credentials.sh reads -- see "is it wanted here?" below.
#
# VERSION-COUPLED: the descriptor this writes is read by Maison builds that carry
# internal/backup/adapter. An older Maison ignores adapter.json entirely and keeps using
# its compiled-in kopia engine against the same repository — which still works, because
# the adapter writes the same snapshots with the same tags. The two are interchangeable
# on one repository by design; that is what makes the cutover reversible.
#
#
# WHY THE CREDENTIALS ARE NOT IN repository.config
# ------------------------------------------------
# This is now the ADAPTER's doing, and is recorded here because it is the reason this
# script writes credentials.env as a separate file at all rather than handing the key to
# `connect` once and forgetting it.
#
# `kopia repository connect` writes the S3 access key and secret into repository.config
# and there is no flag to stop it (--no-persist-credentials governs the repository
# *password*, not the storage credentials). The adapter blanks the two fields afterwards
# and reads the credentials out of credentials.env on every invocation instead, which
# kopia accepts for every ordinary operation and does not write back.
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
# credentials.env. Identity cannot drift because nothing touches the file again — and
# the adapter enforces that from its side too: `connect` returns immediately when a
# configuration already exists rather than rewriting it.
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

YND_ROOT="/DATA/AppData/yundera"
source "$YND_ROOT/scripts/library/log.sh"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
UNIFIED_ENV="$YND_ROOT/.env"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

# ENGINE_ID, ENGINE_IMAGE, ENGINE_BINARY and the two repository.config readers come from
# the library below; it is sourced early because ENGINE_DIR is derived from ENGINE_ID.
source "$YND_ROOT/scripts/library/kopia.sh"

ENGINE="$ENGINE_ID"
ENGINE_DIR="/DATA/AppDataShared/backup/$ENGINE"
CONFIG_FILE="$ENGINE_DIR/repository.config"
PASSWORD_FILE="$ENGINE_DIR/repository.password"
CREDENTIALS_FILE="$ENGINE_DIR/credentials.env"
STATE_FILE="$ENGINE_DIR/state.json"
ADAPTER_FILE="$ENGINE_DIR/adapter.json"
REFRESH_MARKER="$ENGINE_DIR/needs-credentials"
RECOVERY_MARKER="$ENGINE_DIR/needs-recovery"

env_get() { "$ENV_MGR" get "$1" "$2" 2>/dev/null || echo ""; }

# --- is it wanted here? ------------------------------------------------------
#
# BACKUP_ENABLED in .pcs.env, same knob ensure-backup-credentials.sh reads. On a box
# that has never been provisioned this is redundant -- no BACKUP_* means the check
# below exits anyway -- and it is here for the box that HAS been: flipping the knob
# then means "touch nothing", not "reconfigure with whatever is still lying around".
#
# It deliberately leaves the existing repository, password and state file in place.
# Removing them would make the knob destructive in a way its name does not promise:
# repository.password is written exactly once, at create, and is the only thing that
# can read the snapshots already in the space. Maison meanwhile keeps listing and
# restoring from what it finds, which is the correct answer for "stop using this",
# and ensure-backup-credentials.sh has already stopped the credential from being
# renewed -- so the engine ages out on its own within the key's 90-day TTL.
ENABLED="$(env_get BACKUP_ENABLED "$PCS_ENV")"
case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
        log_info "Backups disabled by BACKUP_ENABLED in .pcs.env - not touching the repository"
        exit 0
        ;;
esac

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
# Read by Maison on every engine invocation, and by the kopia UI container once, at
# start. Written through a temporary and renamed, so a backup running at this moment
# reads either the whole old file or the whole new one — never half of each.
#
# MOVED ONLY WHEN THE CONTENTS CHANGE. This used to rename unconditionally, which meant
# the file's mtime advanced on every nightly self-check whether anything had rotated or
# not. ensure-kopia-stack.sh restarts the UI when credentials.env is newer than the
# container — the UI cannot pick up a rotated key any other way — so an unconditional
# rewrite would turn a 90-day event into a nightly restart. Comparing first makes the
# mtime mean what that script reads it to mean.
CRED_TMP="$(mktemp "$ENGINE_DIR/.credentials.XXXXXX")"
cat > "$CRED_TMP" <<EOF
# Generated by ensure-backup-config.sh - DO NOT EDIT.
# Storage credentials for the $ENGINE engine. Rotated roughly every 90 days.
AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY
EOF
if cmp -s "$CRED_TMP" "$CREDENTIALS_FILE"; then
    rm -f "$CRED_TMP"
else
    chmod 600 "$CRED_TMP"
    chown "$PUID:$PGID" "$CRED_TMP" 2>/dev/null || true
    mv -f "$CRED_TMP" "$CREDENTIALS_FILE"
    log_info "Storage credentials changed - rewrote $CREDENTIALS_FILE"
fi

# Unconditional, not inside the branch above: the file may already hold the right
# contents with the wrong mode or owner, written by a template version that predates
# the chown. Same reasoning as deploy-stack.sh's chown of the generated .env.
chmod 600 "$CREDENTIALS_FILE"
chown "$PUID:$PGID" "$CREDENTIALS_FILE" 2>/dev/null || true

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

# --- adapter.json ---------------------------------------------------------------
#
# The descriptor is how Maison learns this engine exists at all. Maison scans
# AppDataShared/backup/*/adapter.json and registers one adapter per file; a directory
# without one is not an engine as far as Maison is concerned, and a box that has never
# been provisioned simply has no engines but the built-in local one.
#
# THE IMAGE IS NAMED HERE AND NOWHERE ELSE, and that is the line that keeps an adapter
# from being a remote-execution surface: what Maison runs as root with every app's data
# in scope is named by the deployment, never by a user. Which repository an engine points
# at stays an ordinary user setting.
#
# It is written only after a successful connect or status, so a box whose repository has
# never opened does not advertise an engine that cannot work.
#
# `container` names the resident engine for `docker exec`, which is worth six or seven
# seconds of container start per command. It is written unconditionally: the container
# may not be up yet — ensure-kopia-stack.sh runs after this script — and Maison verifies
# it against `hostname` before using it, falling back to a one-shot container when they
# disagree or when it is absent. A wrong or missing container costs latency, never
# correctness.
#
# `hostname` is read from repository.config rather than recomputed. Two sides deriving an
# identity independently is how one repository ends up holding two lineages that never
# see each other — invisible until a restore comes back empty.
write_adapter_descriptor() {
    local hostname storage network
    hostname="$(kopia_repo_hostname)"
    storage="$(kopia_repo_storage_type)"
    # A repository on a local filesystem needs no network and must not be given one. Only
    # the one-shot path can honour this; the resident container's network is fixed when
    # the stack deploys it (see ensure-kopia-stack.sh).
    network="default"
    [ "$storage" = "filesystem" ] && network="none"

    cat > "$ADAPTER_FILE" <<EOF
{
  "engineId": "$ENGINE_ID",
  "image": "$ENGINE_IMAGE",
  "container": "kopia-engine",
  "entrypoint": "$ENGINE_BINARY",
  "hostname": "$hostname",
  "network": "$network"
}
EOF
    chmod 644 "$ADAPTER_FILE"
    chown "$PUID:$PGID" "$ADAPTER_FILE" 2>/dev/null || true
}

# --- engine invocation --------------------------------------------------------
#
# The adapter is run one-shot, before any engine container exists — this script is what
# creates the repository those containers then serve.
#
# NO SECRETS ARE PASSED. The adapter reads repository.password and credentials.env out of
# --repo-dir, which it has mounted, so there is nothing to export and nothing to leak
# into another process's `ps`. It also sets the engine's cache and log directories
# itself: the kopia image bakes KOPIA_CACHE_DIRECTORY=/app/cache and KOPIA_LOG_DIR=/app/logs
# into its own environment and those outrank the command line, which the adapter knows
# and this script no longer has to.
#
# ROOT, WITH THE SAME CAPABILITIES MAISON GIVES THE ENGINE — and it has to be, because
# of the CACHE.
#
# This used to run as PUID:PGID, on the reasoning that creating a repository needs no
# more than the engine directory. That reasoning was right about the directory and wrong
# about what is inside it: $ENGINE_DIR/cache is SHARED with the resident engine Maison
# execs into, which runs as 0:0 and therefore creates cache subdirectories owned by root
# with mode 0700. A PUID process cannot read them, so `status` fails with
# "permission denied" on a repository that is perfectly healthy.
#
# The consequence was not a visible error. Any failure here arms needs-credentials (see
# the steady-state branch for why that is deliberate), so the box asked for a fresh
# storage credential every night, forever, against a local permission problem no
# credential can fix — indistinguishable from a flaky provider. Found on wisera,
# 2026-09-16.
#
# Root alone is not enough either: $ENGINE_DIR itself is pcs-owned 0700, so root needs
# DAC_OVERRIDE and DAC_READ_SEARCH to traverse it. The set below mirrors Maison's
# engineCaps exactly; the two must not drift, because they run the same binary against
# the same directory.
engine_run() {
    docker run --rm \
        --user 0:0 \
        --cap-drop ALL \
        --cap-add DAC_READ_SEARCH --cap-add DAC_OVERRIDE \
        --cap-add CHOWN --cap-add FOWNER --cap-add FSETID \
        --security-opt no-new-privileges:true \
        -v /DATA:/DATA \
        "$ENGINE_IMAGE" "$@" \
        --repo-dir="$ENGINE_DIR" 2>&1
}

# engine_detail reduces the adapter's output to something worth putting in a log line.
#
# stdout is NDJSON and stderr is plain text, and engine_run merges them — so a FAILING
# verb leaves its human-readable reason as the only non-JSON line, which is exactly what
# a support log wants. `status` is the awkward case: it exits 0 and reports the reason
# inside its result, so there is no plain line and the JSON is truncated instead.
#
# Deliberately not parsed: this runs before any JSON tooling is guaranteed on the host,
# and the value is a log line, never a decision. Everything the script branches on is an
# exit code or a grep for one fixed field.
engine_detail() {
    local plain
    plain="$(printf '%s' "$1" | grep -v '^{' | tail -2 || true)"
    if [ -n "$plain" ]; then
        printf '%s' "$plain"
    else
        # Everything after `"detail":"`, capped. Taking the HEAD of the envelope instead
        # would spend the budget on field names and cut the reason off the end, which is
        # exactly where the reason lives.
        printf '%s' "$1" | sed -n 's/.*"detail":"//p' | tail -1 | cut -c1-300
    fi
}

# engine_connected reports whether `status` says the repository answered.
#
# The adapter distinguishes "no repository configured" from "configured and unreachable"
# and exits 0 for both — status must answer on a box that has never been provisioned —
# so the answer is in the payload rather than in the exit code.
engine_connected() {
    printf '%s' "$1" | grep -q '"connected":true'
}

# --- connect, or create once --------------------------------------------------

if [ -f "$CONFIG_FILE" ] && [ -f "$PASSWORD_FILE" ]; then
    # Steady state. The configuration is already correct and must not be rewritten;
    # rotation happened above when credentials.env was replaced.

    # THE DESCRIPTOR IS WRITTEN BEFORE THE REACHABILITY CHECK, AND THAT IS THE POINT.
    #
    # It says WHICH ADAPTER SERVES THIS ENGINE, not whether the storage is up today. A
    # configured repository that cannot be reached right now — an expired key, a provider
    # outage, a bucket that has hit its transaction cap — is still this box's backup
    # destination, and Maison has to keep knowing that so it can say the destination is
    # unreachable.
    #
    # Gating it on the probe instead looks careful and is the exact failure this whole
    # design removed: no descriptor means Maison registers no engine for it, which means
    # nothing is configured to write there, which means its "cannot be reached" incident
    # resolves itself. The box then writes backups to its own disk, reports success, and
    # tells nobody. Found on wisera, 2026-09-15, while its bucket was refusing every
    # transaction.
    #
    # The one case that correctly writes no descriptor is below: a box with no repository
    # configuration at all has no engine to describe yet.
    write_adapter_descriptor

    OUT="$(engine_run status)"
    if engine_connected "$OUT"; then
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
    log_warn "Backup repository unreachable - requesting a fresh credential on the next cycle: $(engine_detail "$OUT")"
    exit 0
fi

# Not connected yet. The adapter's `connect` is create-or-connect and idempotent, and it
# refuses to rewrite a configuration that already exists — so the three cases this used
# to branch on (config present, password only, neither) collapse into one call. What
# still has to happen here is minting the password, because only the host can decide to
# generate one and it has to survive the create failing.
if [ ! -f "$PASSWORD_FILE" ]; then
    # No password on this box. Either the space is empty and we are the first box to
    # attach, or this box was rebuilt and the password is only in the user's mailbox.
    # `connect` is what tells the two apart.
    NEW_PASSWORD="$(openssl rand -base64 33 | tr -d '\n')"

    # THE PASSWORD IS WRITTEN BEFORE THE CONNECT, NOT AFTER.
    #
    # Creating a repository initialises it and then connects to it, and the second half
    # can fail on its own — a cache directory it cannot write, a network blip. The format
    # blob is already in storage at that point, encrypted with the password we are
    # holding, so discarding it on failure abandons a repository nobody can ever open
    # again AND leaves storage non-empty, which makes every later run mistake the debris
    # for the user's real backups and refuse to touch the space forever.
    #
    # Writing first inverts the failure: the next run finds a password, takes the same
    # path, and finishes the job. The file is removed again only in the one case where we
    # learn the repository was never ours.
    umask 077
    printf '%s' "$NEW_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    chown "$PUID:$PGID" "$PASSWORD_FILE" 2>/dev/null || true
    MINTED_PASSWORD=1
fi

# --endpoint takes the URL as the credential API returned it. Reducing it to the
# host[:port] kopia actually parses is the adapter's job now, because only the adapter
# knows what its engine parses — this script used to carry that conversion, and it was
# the clearest piece of engine-specific knowledge left on the host.
set +e
OUT="$(engine_run connect \
    --bucket="$BACKUP_BUCKET" \
    --endpoint="$BACKUP_ENDPOINT" \
    --region="$BACKUP_REGION" \
    --prefix="$BACKUP_PREFIX" \
    --hostname="$BACKUP_DEVICE_ID" \
    --username=pcs)"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    chown "$PUID:$PGID" "$CONFIG_FILE" 2>/dev/null || true
    write_adapter_descriptor
    if [ "${MINTED_PASSWORD:-0}" = "1" ]; then
        log_success "Created the backup repository for space $BACKUP_SPACE_ID"
        log_warn "The repository password exists ONLY on this box until the user is mailed a copy"
    else
        log_success "Connected the backup repository (space $BACKUP_SPACE_ID)"
    fi
    exit 0
fi

# 13 is the adapter's "this storage already holds a repository I have no password for".
# It is its own exit code precisely so this branch cannot be reached by matching an error
# string: the only safe response is to stop, and a retry that initialised a second
# repository under the same prefix would strand the first one's snapshots behind a key
# nobody has.
if [ "$RC" -eq 13 ]; then
    if [ "${MINTED_PASSWORD:-0}" = "1" ]; then
        # Not our repository: the password we just minted opens nothing. Remove it, or
        # the next run tries to connect with it and fails with "invalid password"
        # instead of reporting the recoverable truth.
        rm -f "$PASSWORD_FILE"
    fi
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

# Anything else: the repository may or may not have been initialised, and the password on
# disk is the only one that could open it if it was. Keep it and let the next run settle
# the question.
log_error "Could not connect the backup repository: $(engine_detail "$OUT")"
if [ "${MINTED_PASSWORD:-0}" = "1" ]; then
    log_info "Keeping the generated password - the next cycle will try again with it"
fi
exit 1
