#!/bin/bash
# ensure-kopia-stack.sh - Deploy the kopia stack: the resident backup engine, and
# kopia's own web UI behind an AppShield gate.
#
# The engine is a container Maison runs `docker exec` in, rather than one it starts and
# throws away per command. On a PCS a `docker run` costs six to seven seconds before the
# engine's own process begins, which is what made the store's Install button appear dead
# while it looked for an app's backups. See stacks/kopia/docker-compose.yml for the
# measurements and the reasoning — including why the UI and the engine are two
# containers rather than one.
#
# Deployed to /DATA/AppData/kopia as its own stack, alongside maison rather than inside
# it: the repository, its password and its credentials belong to ensure-backup-config.sh,
# and this stack is what reads them. Maison is a consumer.
#
# NOTHING DEPENDS ON THIS SUCCEEDING. If the stack is absent or down, Maison starts a
# one-shot adapter container per command instead — slower, correct in every other
# respect. So this exits 0 on every path that is merely "not applicable here".
#
# The one-shot uses the same image, repository and identity, so it is a slower route
# to the same destination, never a different one. A command that starts in the resident
# container and fails there is not re-run: the backup fails. (Maison's dedicated
# incident for an unreachable engine is designed but not built — maison docs/backup.md.)
#
# ORDERING: must run AFTER ensure-backup-config.sh, which writes the connect.json and
# markers this reads (repository.config itself comes from the engine's `init`/`recover`,
# or an older template's create). Run before it, a fresh box would find no marker and
# no connect.json, and start no engine until the next cycle. It must also run after ensure-mesh-installed.sh — the gate joins
# the `pcs` network and gets its OIDC client from the mesh template's auth-registrar.
set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
# ENGINE_IMAGE, KOPIA_ENGINE_DIR, kopia_repo_hostname and kopia_repo_storage_type,
# shared with ensure-backup-config.sh so the containers started here cannot disagree with
# the repository that script created.
source "$YND_TEMPLATE/scripts/library/kopia.sh"

PCS_ENV="$YND_ROOT/.pcs.env"
STACK_DIR="/DATA/AppData/kopia"

# The UI container. Named here because this script restarts it on credential rotation;
# the engine is never restarted from here.
UI_CONTAINER="kopia-app"

env_get() {
    "$YND_TEMPLATE/scripts/tools/env-file-manager.sh" get "$1" "$2" 2>/dev/null || true
}

# --- is it wanted here? ------------------------------------------------------
#
# The same BACKUP_ENABLED knob ensure-backup-credentials.sh and ensure-backup-config.sh
# read. Unlike those, this one CAN clean up after itself: the containers hold no state
# — the repository, its caches and its logs all live in $KOPIA_ENGINE_DIR, which the
# stack only mounts — so taking them down destroys nothing and leaves Maison on the
# one-shot path it used
# before this stack existed. The UI goes with them, which is correct: there is nothing
# for it to show.
ENABLED="$(env_get BACKUP_ENABLED "$PCS_ENV")"
case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
        if [ -f "$STACK_DIR/docker-compose.yml" ] && docker compose version >/dev/null 2>&1; then
            log_info "Backups disabled by BACKUP_ENABLED in .pcs.env - taking the kopia stack down"
            # No --volumes: the stack declares none, and a future one must not be wiped
            # by this path.
            docker compose --project-directory "$STACK_DIR" \
                -f "$STACK_DIR/docker-compose.yml" down --remove-orphans \
                || log_warn "Kopia stack teardown failed; continuing"
        fi
        exit 0
        ;;
esac

# --- is there a repository for it to serve? ----------------------------------
#
# Three answers, read from files rather than by asking Maison: this script must not
# depend on the dashboard being up.
#
#   repository.config      the whole stack: gate, UI and engine.
#   needs-recovery         THE ENGINE ALONE. The storage holds a repository this box has
#                          no password for, so there is no config yet and the UI cannot
#                          start: its entrypoint reads the password and the config. The
#                          engine has a job, though. When the owner types their key,
#                          Maison runs the adapter's `recover` in it. Leaving the whole
#                          stack out made a re-created box look as if Kopia was never
#                          installed, and pushed `recover` onto a one-shot container.
#                          The UI stays out of the `ui` profile (see the compose) until
#                          `recover` writes repository.config. The next run then adds it.
#   needs-secret           THE ENGINE ALONE, for the same reason. The storage is empty and
#                          the owner has not chosen a password yet, so there is nothing
#                          for the UI to open. The engine runs the adapter's `init` when
#                          they do (Maison, or tools/backup.sh init, which re-runs this
#                          script right after so the UI follows at once).
#   neither                nothing. No credentials yet, or the probe failed:
#                          ensure-backup-config.sh retries it next cycle, and an engine
#                          with no repository to serve would hold its capabilities for
#                          nothing.
RECOVERY_MARKER="$KOPIA_ENGINE_DIR/needs-recovery"
SECRET_MARKER="$KOPIA_ENGINE_DIR/needs-secret"
if [ -f "$KOPIA_ENGINE_DIR/repository.config" ]; then
    ENGINE_ONLY=0
    COMPOSE_PROFILES="ui"
    # The identity snapshots are filed under, read from the repository config rather
    # than computed here — two sides computing it independently is how one repository
    # ends up split into two lineages that never see each other.
    KOPIA_HOSTNAME="$(kopia_repo_hostname)"
elif [ -f "$RECOVERY_MARKER" ] || [ -f "$SECRET_MARKER" ]; then
    # connect.json's hostname is the device id `recover` and `init` pin into the config
    # they write, and the one ensure-backup-config.sh already put in adapter.json. The
    # container must carry it, or Maison finds a mismatch and falls back to a one-shot.
    WAITING_FOR="backup recovery"
    [ -f "$RECOVERY_MARKER" ] || WAITING_FOR="the owner's backup password"
    RECOVERY_HOSTNAME="$(kopia_connect_hostname)"
    if [ -z "$RECOVERY_HOSTNAME" ]; then
        log_warn "Box is waiting for $WAITING_FOR but $KOPIA_ENGINE_DIR/connect.json names no hostname - skipping the kopia stack"
        exit 0
    fi
    ENGINE_ONLY=1
    COMPOSE_PROFILES=""
    KOPIA_HOSTNAME="$(kopia_repo_hostname "$RECOVERY_HOSTNAME")"
else
    log_info "No $KOPIA_ENGINE_DIR/repository.config yet - skipping the kopia stack"
    exit 0
fi

# The engine stamps its container timezone from TZ, so log timestamps inside it match
# the host's. The unified .env does not carry it. Same derivation as the mesh
# template's ensure-maison-stack.sh.
if [ -f /etc/timezone ]; then
    TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"
elif [ -L /etc/localtime ]; then
    TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
else
    TZ="UTC"
fi

# A repository on a local filesystem needs no network and must not be given one. It used
# to get that isolation by accident, because Maison ran those commands in one-shot
# containers with `--network none`; with the engine resident, the stack has to decide it
# at deploy time instead. Read from repository.config rather than inferred from whether
# BACKUP_* is set — the file is what the engine actually connected to. While waiting
# there is no file and the answer is empty: the storage is the bucket `recover` / `init`
# must reach.
STORAGE_TYPE="$(kopia_repo_storage_type)"
ENGINE_NETWORK_INTERNAL="false"
if [ "$STORAGE_TYPE" = "filesystem" ]; then
    ENGINE_NETWORK_INTERNAL="true"
    log_info "Repository is on a local filesystem - the engine network stays internal"
fi

# Names the image, because with `${ENGINE_IMAGE}` in the compose the deployed stack folder
# does not answer "which build is this" from one file — the compose holds the reference
# and the .env holds the value. One log line beats cross-referencing two files.
log_info "Kopia stack: $ENGINE_IMAGE as $KOPIA_HOSTNAME"

"$YND_TEMPLATE/scripts/tools/deploy-stack.sh" kopia "$STACK_DIR" \
    "TZ=$TZ" \
    "ENGINE_IMAGE=$ENGINE_IMAGE" \
    "ENGINE_NETWORK_INTERNAL=$ENGINE_NETWORK_INTERNAL" \
    "KOPIA_HOSTNAME=$KOPIA_HOSTNAME" \
    "COMPOSE_PROFILES=$COMPOSE_PROFILES"

# Compose leaves the containers of an inactive profile running (`up --remove-orphans`
# does not count them as orphans), so a box that had a UI and is now waiting takes
# it down here. The UI would otherwise hold a password that opens nothing. On a box
# that never had one this removes nothing.
if [ "$ENGINE_ONLY" = "1" ]; then
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/docker-compose.yml" \
        --profile ui rm --stop --force kopia kopia-app >/dev/null 2>&1 \
        || log_warn "Could not remove the kopia UI containers; continuing"
fi

# --- credential rotation ------------------------------------------------------
#
# The UI reads the S3 credentials ONCE, from credentials.env, at container start — kopia
# takes them from the environment and offers no file-based flag. They are rotated
# roughly every 90 days by ensure-backup-config.sh, and a server still holding the
# revoked key serves an error where the snapshot list should be, indefinitely, because
# nothing else would ever restart it: deploy-stack.sh's `up -d` is a no-op when the
# compose file and .env are unchanged, and a rotation changes neither.
#
# The engine needs none of this: the adapter reads credentials.env on every invocation,
# which is what makes a rotation take effect on the next backup rather than on a restart.
#
# mtime is the signal, which is only meaningful because ensure-backup-config.sh now
# leaves credentials.env alone when the contents have not changed. If that ever goes
# back to rewriting the file every cycle, this restarts the UI every night.
#
# A restart interrupts a restore running in the UI at that moment. That is a nightly
# script acting on a 90-day event, so the window is small, and the alternative is a UI
# that is silently broken for months.
#
# repository.password is watched the same way. The owner can change it from Maison
# (the adapter's `change-secret` verb promotes the new key into that file), and the UI
# holds the old one in its environment: kopia refuses it on the next open of the
# repository. The engine, again, reads the file per invocation and needs nothing.
STARTED_AT="$(docker inspect -f '{{.State.StartedAt}}' "$UI_CONTAINER" 2>/dev/null || true)"
STARTED_EPOCH=0
[ -n "$STARTED_AT" ] && STARTED_EPOCH="$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)"
if [ "$STARTED_EPOCH" -gt 0 ]; then
    for watched in "$KOPIA_ENGINE_DIR/credentials.env" "$KOPIA_ENGINE_DIR/repository.password"; do
        [ -f "$watched" ] || continue
        WATCHED_MTIME="$(stat -c %Y "$watched" 2>/dev/null || echo 0)"
        if [ "$WATCHED_MTIME" -gt "$STARTED_EPOCH" ]; then
            log_info "$(basename "$watched") is newer than $UI_CONTAINER - restarting it to pick it up"
            docker restart "$UI_CONTAINER" >/dev/null \
                || log_warn "Could not restart $UI_CONTAINER; the UI keeps the old $(basename "$watched") until the next cycle"
            break
        fi
    done
fi

# MAISON ONLY USES AN ENGINE THE ADMIN HAS APPROVED. Since the engine adapter can also
# arrive from a store app, Maison ignores any adapter.json until it has been enabled,
# and binds that approval to the image the engine container runs. A box upgrading to
# such a Maison is approved once, on its first boot, for every engine already there;
# this re-ensures it every night for what that seed misses — a box rebuilt later, or a
# backup.json reset. The deployment provisioned this engine, so the deployment approves
# it, through the admin socket (Maison's docs/config.md), never over HTTP.
#
# Idempotent, and never fatal: an older Maison has no `backup approve` and needs none
# (it uses every descriptor it finds), and a refusal — the engine container down, its
# image not the one adapter.json names — must not stop the rest of the self-check. The
# next run tries again; Maison's own `backup.approval:kopia` incident is what the owner sees.
if docker exec maison-app maison help 2>&1 | grep -q 'backup approve'; then
    if APPROVE_OUT="$(docker exec maison-app maison backup approve "$ENGINE_ID" 2>&1)"; then
        log_info "Maison has $ENGINE_ID approved as a backup engine"
    else
        log_warn "Maison refused to approve $ENGINE_ID as a backup engine: $APPROVE_OUT"
    fi
fi

if [ "$ENGINE_ONLY" = "1" ]; then
    log_success "Kopia engine is up, waiting for $WAITING_FOR - the UI follows once the owner's key opens a repository"
else
    log_success "Kopia stack is up"
fi
