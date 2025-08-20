#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

# Install and configure OpenSSH server

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Install openssh-server only if not already installed
if ! dpkg-query -W openssh-server >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -qq -y openssh-server >/dev/null 2>&1; then
        echo "✗ Failed to install openssh-server. Running with verbose output for debugging:"
        apt-get install -y openssh-server
        exit 1
    fi
fi

# Enable and start SSH service
systemctl enable ssh.service
systemctl start ssh.service

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