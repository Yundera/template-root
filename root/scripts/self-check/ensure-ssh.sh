#!/bin/bash

set -e

# Install and configure OpenSSH server

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Install openssh-server
"$YND_ROOT/scripts/tools/ensure-packages.sh" openssh-server

# Disable password auth and root password login. Ubuntu's default
# sshd_config sources /etc/ssh/sshd_config.d/*.conf, so dropping a
# snippet here overrides the main file without fighting whatever
# distro/cloud-init shipped. Idempotent: rewrite the file every run and
# only reload sshd if the contents actually changed.
HARDEN_FILE="/etc/ssh/sshd_config.d/99-yundera-harden.conf"
HARDEN_CONTENT="# Managed by ensure-ssh.sh — do not edit.
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
"
mkdir -p /etc/ssh/sshd_config.d
if [ ! -f "$HARDEN_FILE" ] || [ "$(cat "$HARDEN_FILE")" != "$HARDEN_CONTENT" ]; then
    printf '%s' "$HARDEN_CONTENT" > "$HARDEN_FILE"
    chmod 0644 "$HARDEN_FILE"
    HARDEN_CHANGED=1
else
    HARDEN_CHANGED=0
fi

# Enable and start SSH service
systemctl enable ssh.service
systemctl start ssh.service

if [ "$HARDEN_CHANGED" = "1" ]; then
    echo "→ Applied SSH hardening (password auth disabled), reloading sshd..."
    systemctl reload ssh.service || systemctl restart ssh.service
fi

# Function to check for SSH issues
check_ssh_issues() {
    local ssh_issues=0

    # Check if SSH service is active and running
    if ! systemctl is-active --quiet ssh.service; then
        echo "SSH service is not active"
        ssh_issues=1
    fi

    # Check if SSH is listening on port 22
    if ! ss -tlnp | grep -q ':22 '; then
        echo "SSH is not listening on port 22"
        ssh_issues=1
    fi

    # Check SSH configuration syntax
    if ! sshd -t 2>/dev/null; then
        echo "SSH configuration has syntax errors"
        ssh_issues=1
    fi

    # Check if SSH service has failed
    if systemctl is-failed --quiet ssh.service; then
        echo "SSH service is in failed state"
        ssh_issues=1
    fi

    return $ssh_issues
}

# Only reconfigure if there are SSH issues
if ! check_ssh_issues; then
    echo "→ SSH issues detected. Reconfiguring openssh-server..."
    dpkg-reconfigure openssh-server

    # Restart SSH service after reconfiguration
    systemctl restart ssh.service

    # Verify SSH is working after reconfiguration
    if check_ssh_issues; then
        echo "✓ SSH has been successfully reconfigured and is working properly."
    else
        echo "✗ SSH issues persist after reconfiguration."
        exit 1
    fi
else
    echo "✓ SSH is working properly. No reconfiguration needed."
fi