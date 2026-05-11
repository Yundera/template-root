#!/bin/bash

set -e

# Ensure PCS User Script
# This script ensures the 'pcs' user exists and has sudo privileges

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

USER_NAME="pcs"

# Ensure sudo is installed
"$YND_ROOT/scripts/tools/ensure-packages.sh" sudo

# Create user if it doesn't exist.
#
# Pin to UID 1000 when that UID is free. Yundera's app composes hardcode
# PUID=1000 (see ensure-casaos-apps-up-to-date.sh), so file ownership on
# /DATA only matches the in-container app user when `pcs` is 1000. On a
# regular fresh PCS that's what `useradd` picks anyway (first user, smallest
# free UID >= UID_MIN). On a *migration target* the orchestrator pre-creates
# a `migration` sudoer (see MigrationTargetBootstrap.ts, pinned at UID 1099);
# without the explicit `-u 1000` here, `useradd` would pick 1100 (max-existing
# + 1, not smallest-free) and the chown-`pcs`-/DATA in ensure-data-partition
# leaves all app data at UID 1100 — postgres/filebrowser then fail with
# "Permission denied" because their container processes still run as PUID=1000.
# Falling back to default useradd if UID 1000 is taken keeps this safe on
# images that have a pre-existing user there (e.g. some cloud-init defaults).
PCS_TARGET_UID=1000
if ! id "$USER_NAME" &>/dev/null; then
    echo "→ Creating user $USER_NAME"
    if ! getent passwd "$PCS_TARGET_UID" >/dev/null 2>&1; then
        useradd -m -u "$PCS_TARGET_UID" -s /bin/bash "$USER_NAME"
    else
        # UID 1000 is in use by someone else — fall back rather than fight it.
        # Operators on such a host should manually align UIDs.
        echo "  ! UID $PCS_TARGET_UID taken by $(getent passwd "$PCS_TARGET_UID" | cut -d: -f1); creating $USER_NAME with default UID"
        useradd -m -s /bin/bash "$USER_NAME"
    fi

    # Uncomment one of these if you need to set a password:
    # passwd "$USER_NAME"  # Interactive password setting
    # echo "$USER_NAME:defaultpassword" | chpasswd  # Non-interactive
fi

# Add user to sudo group if not already there
if ! groups "$USER_NAME" | grep -q "\bsudo\b"; then
    echo "→ Adding user $USER_NAME to sudo group"
    usermod -aG sudo "$USER_NAME"
fi

# Ensure basic folders exist
mkdir -p /DATA/AppData/casaos/apps/yundera/scripts
mkdir -p /DATA/AppData/casaos/apps/yundera/log
mkdir -p /DATA/AppData/yundera/data/certs
mkdir -p /DATA/AppData/yundera/data/caddy/data
mkdir -p /DATA/AppData/yundera/data/caddy/config

touch /DATA/AppData/casaos/apps/yundera/log/yundera.log

chown -R pcs:pcs /DATA/AppData/casaos/apps/yundera/
chown -R pcs:pcs /DATA/AppData/yundera/

echo "✓ User '$USER_NAME' exist and has sudo privileges."