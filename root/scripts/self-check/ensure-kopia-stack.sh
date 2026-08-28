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
# NOTHING DEPENDS ON THIS SUCCEEDING. If the stack is absent or down, Maison falls back
# to a one-shot container per command — slower, and exactly the behaviour that predates
# this script. So this exits 0 on every path that is merely "not applicable here".
#
# ORDERING: must run AFTER ensure-backup-config.sh, which writes the repository.config
# this reads the engine's hostname out of. A box provisioned before that file exists
# would otherwise bake in the synthetic fallback hostname and keep it until the stack is
# next brought up. It must also run after ensure-user-compose-stack-up.sh — the gate
# attaches to the `pcs` network, which the yundera stack owns and creates.
set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"
# KOPIA_IMAGE, KOPIA_ENGINE_DIR and kopia_repo_hostname, shared with
# ensure-backup-config.sh so the containers started here cannot disagree with the
# repository that script created.
source "$YND_ROOT/scripts/library/kopia.sh"

PCS_ENV="$YND_ROOT/.pcs.env"
STACK_DIR="/DATA/AppData/kopia"

# The UI container. Named here because this script restarts it on credential rotation;
# the engine is never restarted from here.
UI_CONTAINER="kopia-app"

# --- legacy location ---------------------------------------------------------
#
# The stack shipped for a few staging cycles as `backup-engine`, deployed to
# /DATA/AppData/backup-engine with a single container of the same name. The project
# name, the container and the directory all changed when the UI was added and the whole
# thing became "kopia, the app". A box that ran the old template therefore has a live
# `backup-engine` project that NOTHING else would ever touch again: `docker compose up`
# on the new project cannot see it, --remove-orphans only reaches orphans of its own
# project, and the old directory is outside the template tree that rsync --delete
# prunes. It would keep running forever, holding the old container name.
#
# Nothing of value is in there: the container held no state, and the repository, its
# caches and its logs all live under /DATA/AppDataShared/backup. So take it down and
# remove the directory outright — unlike the maison rebrand, there is nothing to move.
LEGACY_DIR="/DATA/AppData/backup-engine"
if [ -d "$LEGACY_DIR" ]; then
    if [ -f "$LEGACY_DIR/docker-compose.yml" ] && docker compose version >/dev/null 2>&1; then
        log_info "Removing the legacy backup-engine stack (replaced by kopia)"
        # No --volumes: the stack declared none, and this must not become a path that
        # wipes one a future template adds.
        docker compose --project-directory "$LEGACY_DIR" \
            -f "$LEGACY_DIR/docker-compose.yml" down --remove-orphans \
            || log_warn "Legacy backup-engine teardown failed; continuing"
    fi
    rm -rf "$LEGACY_DIR"
fi

env_get() {
    "$YND_ROOT/scripts/tools/env-file-manager.sh" get "$1" "$2" 2>/dev/null || true
}

# --- is it wanted here? ------------------------------------------------------
#
# The same BACKUP_ENABLED knob ensure-backup-credentials.sh and ensure-backup-config.sh
# read. Unlike those, this one CAN clean up after itself: the containers hold no state
# — the repository, its caches and its logs all live under /DATA/AppDataShared/backup —
# so taking them down destroys nothing and leaves Maison on the one-shot path it used
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
# Without one the engine would sit idle holding capabilities for nothing, and the UI
# would not start at all — its entrypoint reads the repository password and the storage
# credentials from files that do not exist yet. Maison's fallback covers the gap, and
# the next self-check after the repository is configured brings the stack up.
# Deliberately checked by file rather than by asking Maison: this script must not depend
# on the dashboard being up.
if [ ! -f "$KOPIA_ENGINE_DIR/repository.config" ]; then
    log_info "No $KOPIA_ENGINE_DIR/repository.config yet - skipping the kopia stack"
    exit 0
fi

# The engine stamps its container timezone from TZ, so log timestamps inside it match
# the host's. The unified .env does not carry it. Same derivation as
# ensure-maison-stack.sh.
if [ -f /etc/timezone ]; then
    TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"
elif [ -L /etc/localtime ]; then
    TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
else
    TZ="UTC"
fi

# The identity snapshots are filed under, read from the repository config rather than
# computed here — two sides computing it independently is how one repository ends up
# split into two lineages that never see each other.
KOPIA_HOSTNAME="$(kopia_repo_hostname)"
log_info "Kopia stack: $KOPIA_IMAGE as $KOPIA_HOSTNAME"

"$YND_ROOT/scripts/tools/deploy-stack.sh" kopia "$STACK_DIR" \
    "TZ=$TZ" \
    "KOPIA_IMAGE=$KOPIA_IMAGE" \
    "KOPIA_HOSTNAME=$KOPIA_HOSTNAME"

# --- credential rotation ------------------------------------------------------
#
# The UI reads the S3 credentials ONCE, from credentials.env, at container start — kopia
# takes them from the environment and offers no file-based flag. They are rotated
# roughly every 90 days by ensure-backup-config.sh, and a server still holding the
# revoked key serves an error where the snapshot list should be, indefinitely, because
# nothing else would ever restart it: deploy-stack.sh's `up -d` is a no-op when the
# compose file and .env are unchanged, and a rotation changes neither.
#
# The engine needs none of this — Maison passes credentials into every exec.
#
# mtime is the signal, which is only meaningful because ensure-backup-config.sh now
# leaves credentials.env alone when the contents have not changed. If that ever goes
# back to rewriting the file every cycle, this restarts the UI every night.
#
# A restart interrupts a restore running in the UI at that moment. That is a nightly
# script acting on a 90-day event, so the window is small, and the alternative is a UI
# that is silently broken for months.
CRED_FILE="$KOPIA_ENGINE_DIR/credentials.env"
if [ -f "$CRED_FILE" ]; then
    STARTED_AT="$(docker inspect -f '{{.State.StartedAt}}' "$UI_CONTAINER" 2>/dev/null || true)"
    if [ -n "$STARTED_AT" ]; then
        CRED_MTIME="$(stat -c %Y "$CRED_FILE" 2>/dev/null || echo 0)"
        STARTED_EPOCH="$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)"
        if [ "$STARTED_EPOCH" -gt 0 ] && [ "$CRED_MTIME" -gt "$STARTED_EPOCH" ]; then
            log_info "Storage credentials are newer than $UI_CONTAINER - restarting it to pick them up"
            docker restart "$UI_CONTAINER" >/dev/null \
                || log_warn "Could not restart $UI_CONTAINER; the UI keeps the old credentials until the next cycle"
        fi
    fi
fi

log_success "Kopia stack is up"
