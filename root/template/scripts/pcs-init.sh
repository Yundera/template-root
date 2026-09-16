#!/bin/bash
# pcs-init.sh — bootstrap a fresh Ubuntu host into a Yundera PCS.
#
# Run once per host, by the orchestrator over SSH, immediately after
# `.pcs.env` and `.pcs.secret.env` have been staged at $YND_ROOT.
#
# Contract:
#   - $YND_ROOT/.pcs.env and $YND_ROOT/.pcs.secret.env are already on disk.
#   - This script has zero dependencies on the template tree at start time —
#     it fetches the tree itself, then hands off to os-init.sh.
#   - Idempotent on hosts that already have the tree (rsync onto existing
#     content is a no-op-ish, apt-install on satisfied packages is too).
#
# This is the orchestrator-side bootstrap entry. It is FETCHED from jsDelivr
# at create time, not bundled into the orchestrator image — see
# packages/pcs-orchestrator/src/library/provisioning/runHostBootstrap.ts.
#
# Migrations are intentionally skipped BY THIS SCRIPT: this is a first-install
# path with no prior template version to migrate from. Once the @reboot cron
# (installed by ensure-self-check-at-reboot.sh during os-init.sh) is live,
# subsequent ensure-template-sync.sh runs handle migrations on update.
#
# THAT IS NOT THE SAME AS "MIGRATIONS DO NOT RUN ON A CREATE". Step 8 execs
# os-init.sh, which runs the full self-check stack — including
# ensure-template-sync.sh, which runs run-migrations.sh. So every migration
# executes on a fresh host too, against a box where the later ensure scripts
# have not run yet. A migration that assumes state produced later in the same
# cycle fails the create; 2026-09-08-12-move-root-to-maison.sh did exactly that
# and wedged every demo rebuild. Write migrations to no-op on a fresh install.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
PCS_ENV="$YND_ROOT/.pcs.env"

log() { echo "[pcs-init $(date -u +%H:%M:%S)] $*"; }
die() { log "ERROR: $*"; exit 1; }

# 0. Single-writer guard.
#
# Two concurrent pcs-init runs on one host interleave destructively: each
# re-rsyncs the template tree under the other's feet, and each hands off to
# os-init.sh, so the second run can reach the irreversible SSH-key handover
# while the first is still mid-self-check. That is exactly how a demo PCS was
# bricked on 2026-08-23, when an orchestrator pool-claim race handed the same
# VPS to two create pipelines.
#
# Idempotent is not the same as concurrency-safe. Fail loudly and let the
# orchestrator surface it, rather than producing a half-provisioned host.
LOCK_FILE="/var/run/pcs-init.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    die "another pcs-init.sh is already running on this host (lock: $LOCK_FILE) — refusing to run concurrently"
fi

# 1. Validate the orchestrator-staged env files.
#
# The orchestrator scp's .pcs.env / .pcs.secret.env into $YND_ROOT before
# invoking this script (runHostBootstrap.ts, PCS_BOOTSTRAP_ROOT).
#
# The shim that relocated them out of the pre-move root was retired 2026-09-15,
# once every deployment staged at the new one — see doc/auth-history.md. Nothing
# on the box reads the old root.
mkdir -p "$YND_ROOT"

[ -f "$PCS_ENV" ] || die ".pcs.env missing at $PCS_ENV — orchestrator did not stage env files"
UPDATE_URL=$(grep '^UPDATE_URL=' "$PCS_ENV" | cut -d= -f2- || true)
[ -n "$UPDATE_URL" ] || die "UPDATE_URL missing from $PCS_ENV"

# 2. Wait out cloud-init / unattended-upgrades on first boot of fresh VPS.
#    Without this, set -e trips on a transient apt/dpkg lock — the failure
#    mode that motivated this script in the first place. Check all four
#    lock files: cloud-init's `apt-get update` holds lists/lock without
#    necessarily holding dpkg/lock-frontend, so checking only the latter
#    races (seen in prod 2026-04-30: lists/lock held by pid 1054).
APT_LOCKS=(
    /var/lib/apt/lists/lock
    /var/lib/dpkg/lock
    /var/lib/dpkg/lock-frontend
    /var/cache/apt/archives/lock
)
wait_apt_lock() {
    local max=${1:-300} waited=0 f
    while [ "$waited" -lt "$max" ]; do
        local locked=0
        for f in "${APT_LOCKS[@]}"; do
            if [ -f "$f" ] && fuser "$f" >/dev/null 2>&1; then
                locked=1
                break
            fi
        done
        [ "$locked" -eq 0 ] && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}
log "Waiting for apt lock (up to 5 min)..."
wait_apt_lock 300 || log "apt lock still held after 5min, proceeding anyway"

# 3. Install just enough to fetch the tree. Self-checks install everything
#    else (docker, cron, etc.) via scripts-config.txt later. Retry the
#    apt-get calls because cloud-init can grab the lock between our check
#    and the next command — one more wait+retry covers that race.
log "Installing bootstrap prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt_run() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then return 0; fi
        log "apt attempt $attempt failed, waiting for lock and retrying..."
        wait_apt_lock 300 || true
    done
    return 1
}
apt_run apt-get update -y
apt_run apt-get install -y curl unzip ca-certificates rsync

# 4. Ensure the pcs user (every self-check assumes it owns /DATA).
id -u pcs >/dev/null 2>&1 || useradd -m -s /bin/bash pcs

# 5. Fetch + unpack template-root from UPDATE_URL.
log "Downloading template tree from $UPDATE_URL..."
rm -rf /tmp/template-root /tmp/template-root.zip
mkdir -p /tmp/template-root "$YND_ROOT"
curl -fsSL --retry 3 --retry-delay 5 "$UPDATE_URL" -o /tmp/template-root.zip
unzip -q /tmp/template-root.zip -d /tmp/template-root
TMPL_SRC=$(find /tmp/template-root -mindepth 1 -maxdepth 1 -type d | head -1)
[ -d "$TMPL_SRC/root" ]          || die "downloaded tree has no root/ dir"
[ -d "$TMPL_SRC/root/template" ] || die "downloaded tree has no root/template/ dir (pre-split build?)"

# 6. Install the tree. Same three commands as ensure-template-sync.sh, and for
#    the same reason: the template tree goes to $YND_TEMPLATE, and the only
#    things written to $YND_ROOT itself are the two files Maison needs beside
#    its app folder.
#
#    NO --exclude-from HERE ANY MORE, AND NO .ignore REQUIREMENT. That exclude
#    list existed to stop a whole-root rsync trampling state; this rsync does
#    not target the root at all. The only pre-existing files on a fresh box are
#    the .pcs.env / .pcs.secret.env / .ynd.user.env the orchestrator staged
#    minutes ago, and nothing below writes to them.
#
#    NO --delete EITHER: $YND_TEMPLATE is empty on a fresh box, and a
#    provisioning run is the worst possible moment to hand rsync a delete flag.
log "Syncing template tree to $YND_TEMPLATE..."
# Set exec bits on the SOURCE before syncing. Doing it only after the rsync
# (step 7) leaves a window where freshly-synced scripts are on disk but not
# executable; anything reading this tree concurrently — a self-check already
# in flight — then dies with "Script is not executable" / exit 126.
find "$TMPL_SRC/root/template/scripts" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
mkdir -p "$YND_TEMPLATE"
rsync -a "$TMPL_SRC/root/template/" "$YND_TEMPLATE/"
rsync -a "$TMPL_SRC/root/docker-compose.yml" "$YND_ROOT/"
# The Settings tile icon. Maison prefers `.icon.<ext>` beside the compose over
# the compose's `icon:` URL, which is what keeps the tile from going blank on an
# offline box. Delivered here so a box has one from its very first boot — boxes
# created between the 2026-09-08 root move and the subtree split never got one,
# because the only thing writing it was a migration that returned early on the
# fresh-install branch.
rsync -a "$TMPL_SRC/root/icon.svg" "$YND_ROOT/.icon.svg"

# 7. Ownership + exec bits on shipped scripts.
chown -R pcs:pcs /DATA
find "$YND_TEMPLATE/scripts" -name '*.sh' -exec chmod +x {} \;

# 8. Hand off — os-init.sh runs the full self-check stack
#    (scripts-config.txt) which installs Docker, secrets, compose stack,
#    etc., then locks password auth and cleans cloud-init state.
log "Handing off to os-init.sh..."
exec "$YND_TEMPLATE/scripts/tools/os-init.sh"
