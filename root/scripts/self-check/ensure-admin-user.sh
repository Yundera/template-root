#!/bin/bash

set -e

# Maintenance/admin sudoer account.
#
# Created as the future replacement for root for human and dashboard
# access to the host. The orchestrator (proxmox-middleware
# vm_operations/update.py) and the admin container's bind-mount of
# /root/.ssh still target root today; those will migrate to admin in a
# follow-up. Once they do, ensure-ssh.sh's harden snippet can be
# tightened with `PermitRootLogin no`.
#
# Properties:
#   - Locked-but-key-usable password (`*` in shadow): pubkey auth works,
#     password auth impossible. Same posture we want on root.
#   - NOPASSWD sudo: orchestrator/dashboard run unattended.
#   - First-run only: seeds /home/admin/.ssh/authorized_keys from
#     /root/.ssh/authorized_keys (provisioned by the orchestrator).
#     After that, admin manages its own keys independently — this
#     script will not overwrite an existing authorized_keys.

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
USER_NAME="admin"

# Ensure sudo is installed
"$YND_ROOT/scripts/tools/ensure-packages.sh" sudo

# Create user if it doesn't exist
if ! id "$USER_NAME" &>/dev/null; then
    echo "→ Creating user $USER_NAME"
    useradd -m -s /bin/bash "$USER_NAME"
fi

# `*` = no valid password but NOT locked. Pubkey works, password attempts
# fail. Idempotent: setting `*` repeatedly is a no-op effect-wise.
usermod -p '*' "$USER_NAME"

# NOPASSWD sudo via drop-in (avoids editing /etc/sudoers).
SUDOERS_FILE="/etc/sudoers.d/90-admin-nopasswd"
SUDOERS_CONTENT="admin ALL=(ALL) NOPASSWD:ALL
"
if [ ! -f "$SUDOERS_FILE" ] || [ "$(cat "$SUDOERS_FILE")" != "$SUDOERS_CONTENT" ]; then
    printf '%s' "$SUDOERS_CONTENT" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    # Refuse to leave a syntactically broken sudoers file behind.
    visudo -cf "$SUDOERS_FILE" >/dev/null
    echo "→ Installed NOPASSWD sudoers entry for $USER_NAME"
fi

# SSH directory + first-run key seed.
ADMIN_SSH="/home/$USER_NAME/.ssh"
mkdir -p "$ADMIN_SSH"
chmod 700 "$ADMIN_SSH"

if [ ! -s "$ADMIN_SSH/authorized_keys" ] && [ -s /root/.ssh/authorized_keys ]; then
    install -m 600 -o "$USER_NAME" -g "$USER_NAME" \
        /root/.ssh/authorized_keys "$ADMIN_SSH/authorized_keys"
    echo "→ Seeded $ADMIN_SSH/authorized_keys from /root/.ssh/authorized_keys"
fi

chown "$USER_NAME:$USER_NAME" "$ADMIN_SSH"

echo "✓ User '$USER_NAME' ready (key-only login, NOPASSWD sudo)."
