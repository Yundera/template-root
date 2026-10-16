#!/bin/bash
# ensure-backup-config.sh - Turn the BACKUP_* credentials into a connected backup
# repository that Maison can use, and declare the adapter that serves it.
#
# Phase 1 step 4b (BACKUP-STORAGE-PLAN.md §6, §14). Infra provisions, Maison consumes:
# this script owns the storage credentials, the storage coordinates, the waiting-state
# markers and the adapter descriptor; Maison reads what it finds under
# /DATA/AppData/kopia/engine/ and runs the adapter. Maison never sees the JWT and
# never talks to the backup space API.
#
# THE REPOSITORY PASSWORD IS THE OWNER'S (since 2026-10-16). Nobody generates it any more:
# not this script, which used to mint one and leave Maison to mail it, and not Maison. A
# fresh box stops at needs-secret and the repository is created by the engine's `init`
# when the owner chooses a password (onboarding slide via tools/backup.sh, or Maison's
# Backups settings). An existing box with repository.config + repository.password is
# untouched by this: the steady-state branch below is the same as before.
#
# IT RUNS THE ADAPTER, NOT KOPIA. Every engine-specific step this used to carry — the
# create-or-connect dance, kopia's storage flag names, the endpoint URL that has to be
# reduced to a host[:port], the sed that blanks the credentials kopia persists into its
# own config — now lives behind `maison-engine connect` / `probe`, in the image that ships
# the engine. What is left here is engine-neutral: fetch-time state, three markers, and a
# descriptor naming the image.
#
# MUST RUN AFTER ensure-backup-credentials.sh (which fetches BACKUP_*) and BEFORE
# ensure-mesh-installed.sh (whose install is Maison's first boot), so a box that is being
# provisioned for the first time finds its engine described (waiting for the owner's
# password) on Maison's first boot instead of coming up "not configured" and waiting a day.
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
# no repository password — the owner holds it (chosen by them, or, for a box set up
# before 2026-10-16, the copy Maison mailed them). Creating a repository here would
# initialise a SECOND one under the same prefix and leave the real backups invisible.
# So a box with no password only ever PROBES: the engine's `probe` answers "existing"
# and the box is marked as needing recovery; "empty" marks it needs-secret.
#
# RECOVERY IS THE USER'S, AND THIS SCRIPT ONLY KEEPS THE DOOR OPEN. There are two ways out
# of needs-recovery, and neither runs here:
#   - the user types their key into Maison or the onboarding slide (tools/backup.sh
#     recover), which writes it as repository.password.candidate and runs the adapter's
#     `recover` verb: connect-only, never create, with the storage parameters read from
#     connect.json (below);
#   - the user has lost the key and starts over: a reset of the space (onboarding slide,
#     tools/backup.sh reset, or the Yundera dashboard) empties the prefix;
#     ensure-backup-credentials.sh sees the space's resetAt and removes the marker, and
#     the next run of this script probes an empty space and lands in needs-secret.
# Needs-secret has one way out, also not here: the owner chooses a password and the
# engine's `init` creates the repository.
# What this script owes all of them is to keep everything else current while the box
# waits — credentials.env still rotates, state.json and adapter.json are still written,
# and connect.json always describes the storage — and to touch neither the password nor
# the configuration.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"

PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"

# ENGINE_ID, ENGINE_IMAGE, ENGINE_BINARY and the two repository.config readers come from
# the library below; it is sourced early because ENGINE_DIR is derived from ENGINE_ID.
source "$YND_TEMPLATE/scripts/library/kopia.sh"
# stack_env_adopt; BACKUP_* lives in the kopia stack's own .stack.env (library/kopia.sh).
source "$YND_TEMPLATE/scripts/library/env.sh"
STACK_ENV="$KOPIA_STACK_ENV"
# MESH_ENV, for PUID/PGID below.
source "$YND_TEMPLATE/scripts/library/mesh.sh"

ENGINE="$ENGINE_ID"
ENGINE_DIR="$KOPIA_ENGINE_DIR"
LEGACY_DIR="$KOPIA_LEGACY_ENGINE_DIR"
CONFIG_FILE="$ENGINE_DIR/repository.config"
PASSWORD_FILE="$ENGINE_DIR/repository.password"
CREDENTIALS_FILE="$ENGINE_DIR/credentials.env"
STATE_FILE="$ENGINE_DIR/state.json"
ADAPTER_FILE="$ENGINE_DIR/adapter.json"
CONNECT_FILE="$ENGINE_DIR/connect.json"
REFRESH_MARKER="$ENGINE_DIR/needs-credentials"
RECOVERY_MARKER="$ENGINE_DIR/needs-recovery"
# The storage is reachable and empty, and the owner has not chosen a password yet. Written
# here, removed by the engine's `init` when it creates the repository.
SECRET_MARKER="$ENGINE_DIR/needs-secret"

env_get() { "$ENV_MGR" get "$1" "$2" 2>/dev/null || echo ""; }

# ensure-backup-credentials.sh has normally done this already; repeated so this script
# never depends on that one having run first.
kopia_adopt_backup_env

# --- the engine directory moved ----------------------------------------------
#
# From /DATA/AppDataShared/backup/<engine>/ into the engine's own app folder. See
# library/kopia.sh for why; this is the one-way move that gets a live box there.
#
# WHY THIS IS HERE AND NOT IN scripts/migrations/. A migration runs from the NEWLY
# DOWNLOADED template, before ensure-template-sync.sh rsyncs it into place — so on a box
# in `frozen` or `local` mode, or one whose rsync fails, the files would move while the
# INSTALLED copy of this script still pointed at the old path. This script would then
# find no repository.config, take the create branch, hit "found existing data" and arm
# needs-recovery: fail-safe, but backups stop until someone looks. Doing the move inside
# the consumer means the mover and the reader are the same file and cannot disagree about
# where the repository is. ensure-maison-stack.sh moves casadash -> maison the same way,
# for the same reason.
#
# AHEAD OF THE BACKUP_ENABLED GATE BELOW, deliberately. This is a relocation, not a
# reconfiguration: a box with backups switched off still has a repository.password that is
# the only thing able to read its existing snapshots, and leaving that behind in a
# directory nothing maintains any more is how it gets lost. It also means the old tree is
# actually gone everywhere, which is what lets a later release stop looking for it.
#
# ONE-WAY AND IDEMPOTENT: once $ENGINE_DIR exists this whole block is a no-op.
#
# NEVER MERGE. If both exist, the new one wins and the legacy tree is dropped — the same
# call ensure-maison-stack.sh makes. Merging two half-populated engine directories risks
# pairing one repository.config with another repository.password, which reads as a
# corrupt repository rather than as a mistake.
#
# THE FILES ARE MOVED, NEVER RECONNECTED. `repository connect` at the new path would
# rewrite the whole configuration, and a reconnect that omits --override-hostname /
# --override-username refiles the box under the container's own hostname and `root`.
# kopia keys snapshots user@host:path, so that silently re-hashes everything and leaves
# per-source retention pointed at a lineage nothing writes to. repository.config holds
# storage configuration, not its own location, so a plain move is complete.
if [ ! -d "$ENGINE_DIR" ] && [ -d "$LEGACY_DIR" ]; then
    mkdir -p "$(dirname "$ENGINE_DIR")"
    if mv "$LEGACY_DIR" "$ENGINE_DIR"; then
        log_info "Moved the backup engine directory to $ENGINE_DIR"
    else
        # Deferred, not fatal. The legacy tree is untouched and still what every other
        # path reads, so the next cycle tries again.
        log_warn "Could not move $LEGACY_DIR to $ENGINE_DIR - retrying next cycle"
    fi
elif [ -d "$ENGINE_DIR" ] && [ -d "$LEGACY_DIR" ]; then
    log_warn "Both $ENGINE_DIR and $LEGACY_DIR exist - keeping the former, removing the latter"
    rm -rf "$LEGACY_DIR"
fi
# Only ever rmdir: empty means the move took everything, and anything still in there is
# something this script did not put there and must not delete. Failure is expected and
# silent — on most boxes these directories are already gone.
rmdir "/DATA/AppDataShared/backup" 2>/dev/null || true
rmdir "/DATA/AppDataShared" 2>/dev/null || true

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

if [ ! -f "$STACK_ENV" ]; then
    log_info "No $STACK_ENV - nothing to configure"
    exit 0
fi

BACKUP_BUCKET="$(env_get BACKUP_BUCKET "$STACK_ENV")"
BACKUP_PREFIX="$(env_get BACKUP_PREFIX "$STACK_ENV")"
BACKUP_ENDPOINT="$(env_get BACKUP_ENDPOINT "$STACK_ENV")"
BACKUP_REGION="$(env_get BACKUP_REGION "$STACK_ENV")"
BACKUP_DEVICE_ID="$(env_get BACKUP_DEVICE_ID "$STACK_ENV")"
ACCESS_KEY_ID="$(env_get BACKUP_ACCESS_KEY_ID "$STACK_ENV")"
SECRET_ACCESS_KEY="$(env_get BACKUP_SECRET_ACCESS_KEY "$STACK_ENV")"
BACKUP_WRITABLE="$(env_get BACKUP_WRITABLE "$STACK_ENV")"
BACKUP_STATUS="$(env_get BACKUP_STATUS "$STACK_ENV")"
BACKUP_SPACE_ID="$(env_get BACKUP_SPACE_ID "$STACK_ENV")"
BACKUP_EXPIRES_AT="$(env_get BACKUP_EXPIRES_AT "$STACK_ENV")"

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

# --- directories --------------------------------------------------------------
#
# Maison runs the engine container as PUID:PGID, so everything here must be readable
# and writable by that uid rather than by root. cache/ and logs/ are excluded from the
# user-data backup set by pattern on Maison's side.
# PUID/PGID are mesh constants (library/mesh.sh), so they live in the mesh .env.
PUID="$(env_get PUID "$MESH_ENV")"; PUID="${PUID:-1000}"
PGID="$(env_get PGID "$MESH_ENV")"; PGID="${PGID:-1000}"

mkdir -p "$ENGINE_DIR/cache" "$ENGINE_DIR/logs"
# Not recursive: the cache is multi-gigabyte and turns over between runs, and this
# script runs nightly on every box. The directories are chowned so the engine can
# create files in them; each file this script writes is chowned individually below.
# The app folder itself is left alone: it is deploy-stack.sh's, and it holds the stack's
# compose and .env beside this tree.
chown "$PUID:$PGID" "$ENGINE_DIR" "$ENGINE_DIR/cache" "$ENGINE_DIR/logs" 2>/dev/null || true
chmod 700 "$ENGINE_DIR"

# --- connect.json ---------------------------------------------------------------
#
# The storage parameters `maison-engine connect` is given below, as a file. The adapter's
# `recover`, `init` and `probe` verbs read them from here: the first two are started by
# Maison, which never sees BACKUP_* and must not learn the storage layout from anywhere
# but this directory, and all three have to reach exactly the repository this script
# would have connected to.
#
# ONE SET OF VALUES, BUILT ONCE. The CONNECT_* variables feed both this file and the
# `connect` call further down. Two copies of "which bucket, which prefix, which identity"
# drifting apart is the failure this exists to rule out: a recover that connected under a
# different hostname than create would have used opens a second lineage in the same
# repository — invisible until a restore comes back empty.
#
# NON-SECRET, so 644: bucket, endpoint, region and prefix are storage coordinates, and the
# key that opens them is in credentials.env (600). Written EVERY RUN and BEFORE the
# needs-recovery check, since a box in recovery is precisely the one that needs it, and
# replaced only when the contents change, like credentials.env.
CONNECT_BUCKET="$BACKUP_BUCKET"
CONNECT_ENDPOINT="$BACKUP_ENDPOINT"
CONNECT_REGION="$BACKUP_REGION"
CONNECT_PREFIX="$BACKUP_PREFIX"
CONNECT_HOSTNAME="$BACKUP_DEVICE_ID"
CONNECT_USERNAME="pcs"

CONNECT_TMP="$(mktemp "$ENGINE_DIR/.connect.XXXXXX")"
cat > "$CONNECT_TMP" <<EOF
{
  "bucket": "$CONNECT_BUCKET",
  "endpoint": "$CONNECT_ENDPOINT",
  "region": "$CONNECT_REGION",
  "prefix": "$CONNECT_PREFIX",
  "hostname": "$CONNECT_HOSTNAME",
  "username": "$CONNECT_USERNAME"
}
EOF
if cmp -s "$CONNECT_TMP" "$CONNECT_FILE"; then
    rm -f "$CONNECT_TMP"
else
    mv -f "$CONNECT_TMP" "$CONNECT_FILE"
fi
# Unconditional, as for credentials.env below — and here it is also what turns mktemp's
# 600 into the 644 a non-secret file gets.
chmod 644 "$CONNECT_FILE"
chown "$PUID:$PGID" "$CONNECT_FILE" 2>/dev/null || true

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
BACKUP_LABEL="$(env_get BACKUP_LABEL "$STACK_ENV")"
BACKUP_LABEL="${BACKUP_LABEL:-Yundera Backup Storage}"

# recoveryHelpUrl is where Maison sends a user who is in recovery and has NOT got the key:
# the dashboard page that resets the space. Like label, it describes the space's provider,
# not the engine, so it is decided here. BACKUP_RECOVERY_HELP_URL in .pcs.env overrides it
# (a staging orchestrator's dashboard, say).
RECOVERY_HELP_URL="$(env_get BACKUP_RECOVERY_HELP_URL "$PCS_ENV")"
RECOVERY_HELP_URL="${RECOVERY_HELP_URL:-https://app.yundera.com/dashboard/backup}"

cat > "$STATE_FILE" <<EOF
{
  "engine": "$ENGINE",
  "label": "$BACKUP_LABEL",
  "spaceId": "$BACKUP_SPACE_ID",
  "deviceId": "$BACKUP_DEVICE_ID",
  "writable": ${BACKUP_WRITABLE:-true},
  "status": "${BACKUP_STATUS:-ok}",
  "credentialExpiresAt": "$BACKUP_EXPIRES_AT",
  "recoveryHelpUrl": "$RECOVERY_HELP_URL"
}
EOF
chmod 644 "$STATE_FILE"
chown "$PUID:$PGID" "$STATE_FILE" 2>/dev/null || true

# --- adapter.json ---------------------------------------------------------------
#
# The descriptor is how Maison learns this engine exists at all. Maison scans
# AppData/*/engine/adapter.json and registers one adapter per file; a directory without
# one is not an engine as far as Maison is concerned, and a box that has never been
# provisioned simply has no engines but the built-in local one.
#
# The descriptor's engineId has to equal the app folder it sits in — Maison refuses it
# otherwise, so that one engine's configuration cannot be read into another engine's
# provider. ENGINE_ID is that name, which is why the library derives both from it.
#
# THE IMAGE IS NAMED HERE AND NOWHERE ELSE, and that is the line that keeps an adapter
# from being a remote-execution surface: what Maison runs as root with every app's data
# in scope is named by the deployment, never by a user. Which repository an engine points
# at stays an ordinary user setting.
#
# It is written whenever there is an engine to describe: a repository configuration (the
# steady state, reachable or not), a successful connect, or a box waiting in
# needs-recovery or needs-secret. The last two have no configuration and are advertised
# anyway, because the descriptor is how Maison finds the engine at all — and an engine
# Maison cannot see is one whose recovery or set-a-password form it cannot show. The
# adapter's `status` reports needsRecovery / needsSecret from the markers, so Maison
# tells those states apart from a working engine. A box whose storage has never answered
# a probe still advertises nothing.
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
# see each other — invisible until a restore comes back empty. With no repository.config
# (needs-recovery, needs-secret) it falls back to CONNECT_HOSTNAME, the device id
# `connect` and the adapter's `recover` and `init` pin into the configuration they
# write, rather than to the library's synthetic default: snapshots Maison takes after a
# recovery or an init and before this script next runs are then already filed under the
# identity that configuration names.
write_adapter_descriptor() {
    local hostname storage network
    hostname="$(kopia_repo_hostname "$CONNECT_HOSTNAME")"
    storage="$(kopia_repo_storage_type)"
    # A repository on a local filesystem needs no network and must not be given one. Only
    # the one-shot path can honour this; the resident container's network is fixed when
    # the stack deploys it (see ensure-kopia-stack.sh).
    network="default"
    [ "$storage" = "filesystem" ] && network="none"

    # "secret" is the engine's own account of its key, for Maison's escrow, page and
    # mail: kopia's name for it, the file that holds it, and that it exists nowhere but
    # this box. Maison reads it from this file rather than asking the engine, so it
    # still knows where the key is on a box whose engine container is down. A Maison
    # older than the block ignores it; a newer one falls back to the same values when
    # it is absent.
    cat > "$ADAPTER_FILE" <<EOF
{
  "engineId": "$ENGINE_ID",
  "image": "$ENGINE_IMAGE",
  "container": "kopia-engine",
  "entrypoint": "$ENGINE_BINARY",
  "hostname": "$hostname",
  "network": "$network",
  "secret": {
    "label": "Kopia repository password",
    "file": "repository.password",
    "escrow": true
  }
}
EOF
    chmod 644 "$ADAPTER_FILE"
    chown "$PUID:$PGID" "$ADAPTER_FILE" 2>/dev/null || true
}

# --- a box in recovery stops here ---------------------------------------------
#
# AFTER connect.json, credentials.env and state.json, and that order is the point. This
# check used to sit before all of them, which froze the storage key on the day the marker
# was written: a user entering their key weeks later would find `recover` failing on an
# expired credential, with nothing able to renew it because rotation was skipped too.
# Everything above is safe in recovery — none of it touches the repository password or
# configuration.
#
# What must not happen is below: probing or running `connect`, which on this storage
# can only answer "existing" again or, if a later bug let it, create a second
# repository over the user's snapshots.
#
# The descriptor IS written, so Maison registers the engine and can offer key entry.
# (A box in needs-secret does NOT stop here: it re-probes below, every run.)
if [ -f "$RECOVERY_MARKER" ]; then
    # The two waiting states are exclusive; recovery is the one that holds data.
    rm -f "$SECRET_MARKER"
    write_adapter_descriptor
    log_warn "This box is marked as needing backup recovery - not touching the repository (key entry in Maison, or a reset from the dashboard)"
    exit 0
fi

# --- engine invocation --------------------------------------------------------
#
# The adapter is run one-shot, before any engine container exists — this script probes
# the storage (and checks the steady-state repository) before ensure-kopia-stack.sh
# decides which containers to start.
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

# --- the steady state -------------------------------------------------------------

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

    # A box waiting for its password has none of either; the engine's `init` removes
    # the marker itself, and this only sweeps one an interrupted run left behind.
    rm -f "$SECRET_MARKER"

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

# write_recovery_marker records that the storage holds a repository this box has no
# password for. ensure-backup-credentials.sh compares its detectedAt with the space's
# resetAt, so the timestamp is the moment of detection, never rewritten while it stands.
write_recovery_marker() {
    rm -f "$SECRET_MARKER"
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
}

# --- no password: probe, and wait for the owner -------------------------------
#
# THE PASSWORD IS THE OWNER'S, AND THIS SCRIPT NEVER MAKES ONE. It used to mint a random
# one here, create the repository with it, and leave Maison to mail a copy. A fresh box
# now stops at "storage reachable and empty": the engine is described, the storage
# credentials rotate, and the repository is created only when the owner picks a password
# — on the onboarding slide (tools/backup.sh init) or in Maison's Backups settings. Both
# end in the adapter's `init` verb, which reads that password from
# repository.password.initial (written by Maison, removed by the engine on every path),
# runs `repository create`, promotes the file to repository.password and removes the
# needs-secret marker. See doc/pcs-onboarding.md › Backups.
#
# `probe` is what tells the two no-password cases apart, with no side effect on the
# storage: a `repository connect` attempt with a throwaway password. "Not initialized"
# is an empty space; "invalid password" is a repository someone else created.
#
#   empty      needs-secret. The marker is the host's account of the state, read by the
#              adapter's `status` (needsSecret) and by tools/backup.sh. It keeps its first
#              detectedAt while it stands.
#   existing   needs-recovery, exactly the marker the old create path wrote on exit 13:
#              a rebuilt or re-created box. The owner restores with the old password, or
#              starts over (a space reset, which ensure-backup-credentials.sh turns back
#              into an empty space, so the next run lands in needs-secret).
#
# RE-PROBED ON EVERY RUN while the marker stands, rather than trusted. A second box on
# the same space may create a repository while this one waits; `init` would then refuse
# with 13 anyway, but turning the marker into needs-recovery here is what lets the slide
# offer the restore it actually needs. A probe costs one connect attempt.
#
# The descriptor is written in both cases: an engine Maison cannot see is one whose
# password form it cannot show.
if [ ! -f "$PASSWORD_FILE" ]; then
    if [ -f "$CONFIG_FILE" ]; then
        # A configuration with no password beside it is nothing this template writes: the
        # engine's `init` and `recover` promote the password before (or with) the config.
        # Never guess one, and never let `init` near it — it refuses over a config anyway.
        write_adapter_descriptor
        log_error "$CONFIG_FILE exists without $PASSWORD_FILE - not touching the repository (key entry in Maison, or a reset from the dashboard)"
        exit 1
    fi

    set +e
    OUT="$(engine_run probe)"
    RC=$?
    set -e

    if [ "$RC" -ne 0 ]; then
        # Keep a box already waiting for its password visible to Maison: the storage
        # being unreachable tonight changes nothing about what the owner has to do.
        if [ -f "$SECRET_MARKER" ]; then
            write_adapter_descriptor
        fi
        # 1 is the adapter's own failure, which on a probe is the storage refusing us —
        # the steady-state branch's reasoning applies: one extra mint is cheap, a dead
        # key nobody renews is not. Anything else (docker could not start the image,
        # an engine with no `probe`) is no credential's fault.
        if [ "$RC" -eq 1 ]; then
            touch "$REFRESH_MARKER"
            chown "$PUID:$PGID" "$REFRESH_MARKER" 2>/dev/null || true
        fi
        log_error "Could not probe the backup storage (exit $RC): $(engine_detail "$OUT")"
        exit 1
    fi

    if printf '%s' "$OUT" | grep -q '"storage"[[:space:]]*:[[:space:]]*"existing"'; then
        # THE REBUILT BOX. Stop before doing damage.
        write_recovery_marker
        write_adapter_descriptor
        log_error "Backup space $BACKUP_SPACE_ID already holds a repository and this box has no password."
        log_error "Not creating a second one. The owner's encryption password is required to recover (or a reset of the space to start over)."
        exit 0
    fi

    if printf '%s' "$OUT" | grep -q '"storage"[[:space:]]*:[[:space:]]*"empty"'; then
        if [ ! -f "$SECRET_MARKER" ]; then
            cat > "$SECRET_MARKER" <<EOF
{
  "reason": "no-password",
  "spaceId": "$BACKUP_SPACE_ID",
  "prefix": "$BACKUP_PREFIX",
  "detectedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
            chmod 644 "$SECRET_MARKER"
            chown "$PUID:$PGID" "$SECRET_MARKER" 2>/dev/null || true
            log_info "Backup space $BACKUP_SPACE_ID is empty - waiting for the owner to choose an encryption password"
        fi
        write_adapter_descriptor
        log_warn "Backups are waiting for the owner's encryption password (onboarding, or Maison > Settings > Backups)"
        exit 0
    fi

    log_error "Unexpected answer from the engine's probe: $(engine_detail "$OUT")"
    exit 1
fi

# --- a password without a configuration ----------------------------------------
#
# Not reached by the current flow, which never writes repository.password without the
# engine's `init` or `recover` writing repository.config with it. It is a box an older
# template left half-done: a password it minted before a create that failed halfway.
# The format blob may already be in storage, encrypted with exactly this password, so
# the password is kept and `connect` (create-or-connect, idempotent) finishes the job.
#
# --endpoint takes the URL as the credential API returned it. Reducing it to the
# host[:port] kopia actually parses is the adapter's job, because only the adapter
# knows what its engine parses.
set +e
# The values are connect.json's (see there): one set, so the two cannot disagree.
OUT="$(engine_run connect \
    --bucket="$CONNECT_BUCKET" \
    --endpoint="$CONNECT_ENDPOINT" \
    --region="$CONNECT_REGION" \
    --prefix="$CONNECT_PREFIX" \
    --hostname="$CONNECT_HOSTNAME" \
    --username="$CONNECT_USERNAME")"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    chown "$PUID:$PGID" "$CONFIG_FILE" 2>/dev/null || true
    rm -f "$SECRET_MARKER"
    write_adapter_descriptor
    log_success "Connected the backup repository (space $BACKUP_SPACE_ID)"
    exit 0
fi

# 13 is the adapter's "this storage already holds a repository I have no password for",
# and 14 (engine 1.4.0+) "the password on this box does not open the repository there".
# Both are their own exit codes precisely so this branch cannot be reached by matching
# an error string: the only safe response is to stop, and a retry that initialised a
# second repository under the same prefix would strand the first one's snapshots behind
# a key nobody has.
if [ "$RC" -eq 13 ] || [ "$RC" -eq 14 ]; then
    # The password on disk is KEPT, as it always was on 13: 13 can also follow a connect
    # that failed for another reason before the create found data, and then it may be
    # the right one. It cannot loop: the recovery marker stops every later run before
    # this point. If the owner resets the space instead of recovering,
    # ensure-backup-credentials.sh moves it aside with the marker, so the fresh
    # repository is created under a password the owner chooses.
    write_recovery_marker
    # Maison must see the engine to offer key entry, and without this it would wait a
    # whole cycle for the next run to write the descriptor.
    write_adapter_descriptor
    log_error "Backup space $BACKUP_SPACE_ID already holds a repository this box's password does not open (engine exit $RC)."
    log_error "Not creating a second one. The owner's encryption password is required to recover."
    exit 0
fi

# Anything else: the repository may or may not have been initialised, and the password on
# disk is the only one that could open it if it was. Keep it and let the next run settle
# the question.
log_error "Could not connect the backup repository: $(engine_detail "$OUT")"
log_info "Keeping the existing password - the next cycle will try again with it"
exit 1
