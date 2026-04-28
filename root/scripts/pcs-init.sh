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
# Migrations are intentionally skipped here: this is a first-install path
# with no prior template version to migrate from. Once the @reboot cron
# (installed by ensure-self-check-at-reboot.sh during os-init.sh) is live,
# subsequent ensure-template-sync.sh runs handle migrations on update.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV="$YND_ROOT/.pcs.env"

log() { echo "[pcs-init $(date -u +%H:%M:%S)] $*"; }
die() { log "ERROR: $*"; exit 1; }

# 1. Validate orchestrator-staged env file.
[ -f "$PCS_ENV" ] || die ".pcs.env missing at $PCS_ENV — orchestrator did not stage env files"
UPDATE_URL=$(grep '^UPDATE_URL=' "$PCS_ENV" | cut -d= -f2- || true)
[ -n "$UPDATE_URL" ] || die "UPDATE_URL missing from $PCS_ENV"

# 2. Wait out cloud-init / unattended-upgrades on first boot of fresh VPS.
#    Without this, set -e trips on a transient dpkg lock — the failure
#    mode that motivated this script in the first place.
log "Waiting for apt lock (up to 5 min)..."
for _ in $(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 5
done

# 3. Install just enough to fetch the tree. Self-checks install everything
#    else (docker, cron, etc.) via scripts-config.txt later.
log "Installing bootstrap prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl unzip ca-certificates rsync

# 4. Ensure the pcs user (every self-check assumes it owns /DATA).
id -u pcs >/dev/null 2>&1 || useradd -m -s /bin/bash pcs

# 5. Fetch + unpack template-root from UPDATE_URL.
log "Downloading template tree from $UPDATE_URL..."
rm -rf /tmp/template-root /tmp/template-root.zip
mkdir -p /tmp/template-root "$YND_ROOT"
curl -fsSL --retry 3 --retry-delay 5 "$UPDATE_URL" -o /tmp/template-root.zip
unzip -q /tmp/template-root.zip -d /tmp/template-root
TMPL_SRC=$(find /tmp/template-root -mindepth 1 -maxdepth 1 -type d | head -1)
[ -d "$TMPL_SRC/root" ]         || die "downloaded tree has no root/ dir"
[ -f "$TMPL_SRC/root/.ignore" ] || die ".ignore missing from downloaded tree"

# 6. rsync onto $YND_ROOT, honouring the same .ignore that
#    ensure-template-sync.sh uses (preserves .pcs.env / .pcs.secret.env /
#    .ynd.user.env that we — or a previous run — staged).
log "Syncing tree to $YND_ROOT..."
rsync -a --exclude-from="$TMPL_SRC/root/.ignore" "$TMPL_SRC/root/" "$YND_ROOT/"

# 7. Ownership + exec bits on shipped scripts.
chown -R pcs:pcs /DATA
find "$YND_ROOT/scripts" -name '*.sh' -exec chmod +x {} \;

# 8. Hand off — os-init.sh runs the full self-check stack
#    (scripts-config.txt) which installs Docker, secrets, compose stack,
#    etc., then locks password auth and cleans cloud-init state.
log "Handing off to os-init.sh..."
exec "$YND_ROOT/scripts/tools/os-init.sh"
