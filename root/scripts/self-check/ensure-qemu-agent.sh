#!/bin/bash

set -e
export DEBIAN_FRONTEND=noninteractive

# Ensure QEMU Guest Agent Script
# This script ensures QEMU guest agent is installed and running

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Install QEMU guest agent
if ! dpkg-query -W qemu-guest-agent >/dev/null 2>&1; then
    [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -qq -y qemu-guest-agent >/dev/null 2>&1; then
        echo "✗ Failed to install qemu-guest-agent. Running with verbose output for debugging:"
        [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
        apt-get install -y qemu-guest-agent
        exit 1
    fi
fi

# Enable and start QEMU guest agent service
#systemctl enable qemu-guest-agent # apparently not needed, as it is enabled by default in Ubuntu 22.04
systemctl start qemu-guest-agent

echo "✓ QEMU Guest Agent is installed and running"