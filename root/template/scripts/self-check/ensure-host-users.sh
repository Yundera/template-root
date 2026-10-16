#!/bin/bash

set -e

# Host accounts and the tree they own. Three steps, in this order:
#   1. `pcs` — the sudoer that owns /DATA/AppData/yundera and the mesh data
#      skeleton (UID 1000, matching the PUID every app compose runs as).
#   2. Exec bits + pcs ownership on every script in the template tree.
#   3. `admin` — the maintenance sudoer humans (support, owner) SSH in as.
# Merged from ensure-pcs-user.sh, ensure-script-executable.sh and
# ensure-admin-user.sh (2026-10-16); the old files are removed by the next
# template sync's `rsync --delete`.

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"

# Ensure sudo is installed
"$YND_TEMPLATE/scripts/tools/ensure-packages.sh" sudo

# ---------------------------------------------------------------------------
# 1. The `pcs` user
# ---------------------------------------------------------------------------

PCS_USER="pcs"

# Create user if it doesn't exist.
#
# Pin to UID 1000 when that UID is free. Yundera's app composes hardcode
# PUID=1000 (Maison writes it into every app's .env), so file ownership on
# /DATA only matches the in-container app user when `pcs` is 1000. On a
# regular fresh PCS that's what `useradd` picks anyway (first user, smallest
# free UID >= UID_MIN). On a *migration target* the orchestrator pre-creates
# a `migration` sudoer (see MigrationTargetBootstrap.ts, pinned at UID 1099);
# without the explicit `-u 1000` here, `useradd` would pick 1100 (max-existing
# + 1, not smallest-free) and the chown of /DATA below leaves all app data
# at UID 1100 — postgres/filebrowser then fail with "Permission denied"
# because their container processes still run as PUID=1000.
# Falling back to default useradd if UID 1000 is taken keeps this safe on
# images that have a pre-existing user there (e.g. some cloud-init defaults).
PCS_TARGET_UID=1000
if ! id "$PCS_USER" &>/dev/null; then
    echo "→ Creating user $PCS_USER"
    if ! getent passwd "$PCS_TARGET_UID" >/dev/null 2>&1; then
        useradd -m -u "$PCS_TARGET_UID" -s /bin/bash "$PCS_USER"
    else
        # UID 1000 is in use by someone else — fall back rather than fight it.
        # Operators on such a host should manually align UIDs.
        echo "  ! UID $PCS_TARGET_UID taken by $(getent passwd "$PCS_TARGET_UID" | cut -d: -f1); creating $PCS_USER with default UID"
        useradd -m -s /bin/bash "$PCS_USER"
    fi

    # Uncomment one of these if you need to set a password:
    # passwd "$PCS_USER"  # Interactive password setting
    # echo "$PCS_USER:defaultpassword" | chpasswd  # Non-interactive
fi

# Add user to sudo group if not already there
if ! groups "$PCS_USER" | grep -q "\bsudo\b"; then
    echo "→ Adding user $PCS_USER to sudo group"
    usermod -aG sudo "$PCS_USER"
fi

# Ensure basic folders exist
mkdir -p /DATA/AppData/yundera/template/scripts
mkdir -p /DATA/AppData/yundera/log

# The mesh stack's runtime data lives in the mesh stack's folder (moved out of
# the yundera root by migrations/2026-10-01-10-move-state-into-stack-folders.sh,
# which treats this skeleton of empty directories as nothing in its way).
MESH_DATA="/DATA/AppData/mesh/data"
mkdir -p "$MESH_DATA/certs"
# data/ca holds only the mesh-router CA: mesh-router-agent writes it there
# (CA_CERT_PATH) so Dex can mount a CA without also mounting the key.pem beside
# it (the AppShield gates no longer read it — they reach Dex by container name). Declared here with its sibling rather than left to Docker to
# invent on the agent's mount, so the layout is stated in one place and the chown
# below covers it like the rest of the tree.
mkdir -p "$MESH_DATA/ca"
mkdir -p "$MESH_DATA/caddy/data"
mkdir -p "$MESH_DATA/caddy/config"

touch /DATA/AppData/yundera/log/yundera.log

chown -R pcs:pcs /DATA/AppData/yundera/
chown -R pcs:pcs "$MESH_DATA"

echo "✓ User '$PCS_USER' exist and has sudo privileges."

# ---------------------------------------------------------------------------
# 2. Script exec bits and ownership
# ---------------------------------------------------------------------------

SCRIPT_DIR="$YND_TEMPLATE/scripts"
count=0

# Make all script files executable and owned
while read -r script; do
    chmod +x "$script"
    chown pcs:pcs "$script"
    count=$((count + 1))
done < <(find "$SCRIPT_DIR" -type f -exec grep -l '^#!/' {} \;)

echo "✓ Scripts executable and owned by pcs: $count files."

# ---------------------------------------------------------------------------
# 3. The `admin` user
# ---------------------------------------------------------------------------
#
# Maintenance/admin sudoer account.
#
# Replaces root for human access to the host: Yundera support's key and the
# owner's own keys land here. (settings-center-app 1.x also SSHed in as `admin`;
# 2.x runs host actions through the Docker socket instead.) The orchestrator (proxmox-middleware
# vm_operations/update.py) still targets root today; once it migrates,
# ensure-ssh.sh's harden snippet can be tightened with `PermitRootLogin
# no`.
#
# Properties:
#   - Locked-but-key-usable password (`*` in shadow): pubkey auth works,
#     password auth impossible. Same posture we want on root.
#   - NOPASSWD sudo: support and the orchestrator run unattended.
#   - Does NOT seed authorized_keys. admin's authorized_keys is populated
#     solely by ensure-support-key.sh with the API-sourced support
#     key. The orchestrator's create-time bootstrap ("perso") key is seeded
#     into /root only and never copied here, so it cannot persist on the
#     handed-over PCS. clear-root-ssh-keys.sh drops it from /root at handover.

ADMIN_USER="admin"

# Create user if it doesn't exist. Cloud-init on some Ubuntu images pre-creates
# an `admin` group; useradd's default tries to create a same-named group and
# fails with exit 9. Reuse the existing group when present.
if ! id "$ADMIN_USER" &>/dev/null; then
    echo "→ Creating user $ADMIN_USER"
    if getent group "$ADMIN_USER" >/dev/null; then
        useradd -m -s /bin/bash -g "$ADMIN_USER" "$ADMIN_USER"
    else
        useradd -m -s /bin/bash "$ADMIN_USER"
    fi
fi

# `*` = no valid password but NOT locked. Pubkey works, password attempts
# fail. Idempotent: setting `*` repeatedly is a no-op effect-wise.
usermod -p '*' "$ADMIN_USER"

# NOPASSWD sudo via drop-in (avoids editing /etc/sudoers).
SUDOERS_FILE="/etc/sudoers.d/90-admin-nopasswd"
SUDOERS_CONTENT="admin ALL=(ALL) NOPASSWD:ALL
"
if [ ! -f "$SUDOERS_FILE" ] || [ "$(cat "$SUDOERS_FILE")" != "$SUDOERS_CONTENT" ]; then
    printf '%s' "$SUDOERS_CONTENT" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    # Refuse to leave a syntactically broken sudoers file behind.
    visudo -cf "$SUDOERS_FILE" >/dev/null
    echo "→ Installed NOPASSWD sudoers entry for $ADMIN_USER"
fi

# Ensure /home/admin itself is admin-owned. Two paths produce a root-owned
# home dir even though sshd-as-admin still works (sshd only needs the .ssh
# subdir to be admin-readable):
#   1. Some cloud-init images pre-create the admin user WITHOUT a home dir.
#      The `if ! id …; then useradd -m` block above is then a no-op, and
#      the first mkdir under /home/admin (next line, run as root) creates
#      both /home/admin and /home/admin/.ssh owned by root:root mode 755.
#   2. The settings-center-app container declares `/home/admin/.ssh/` as a
#      bind-mount source (root/docker-compose.yml). If Docker brings up
#      that stack before this script has run, the daemon auto-creates the
#      path as root:root.
# Either way admin can `cd` into its home but not create new files there,
# which silently breaks anything that wants to write under /home/admin —
# notably the migration pushKey step before it was moved off /home/admin.
# Idempotent: mkdir -p + chown is a no-op when state is already correct.
ADMIN_HOME="/home/$ADMIN_USER"
mkdir -p "$ADMIN_HOME"
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME"

# SSH directory only — deliberately NO key seed.
#
# admin's authorized_keys is owned end-to-end by ensure-support-key.sh
# (the API-sourced support key). Copying /root/.ssh/authorized_keys here —
# as this script used to — would persist the orchestrator's create-time
# bootstrap ("perso") key on the handed-over PCS, which is exactly what the
# key-separation work removes. root's key is cleared by clear-root-ssh-keys.sh
# at handover; admin only ever gets the support key.
ADMIN_SSH="/home/$ADMIN_USER/.ssh"
mkdir -p "$ADMIN_SSH"
chmod 700 "$ADMIN_SSH"
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_SSH"

echo "✓ User '$ADMIN_USER' ready (key-only login, NOPASSWD sudo)."
