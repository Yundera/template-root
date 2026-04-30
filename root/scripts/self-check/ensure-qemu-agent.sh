#!/bin/bash

set -e

# Ensure QEMU Guest Agent Script
# This script ensures QEMU guest agent is installed and running

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Provider gate — the qemu-guest-agent service needs a virtio-serial host
# channel that only Proxmox (and some bare-KVM setups) expose. Cloud
# providers like Contabo do not, so starting the service hangs and fails.
# YND_PROVIDER is resolved and exported by self-check.sh; defaults to
# "proxmox" for standalone invocations.
if [ "${YND_PROVIDER:-proxmox}" != "proxmox" ]; then
    echo "[YND_PROVIDER=${YND_PROVIDER}] no virtio-serial host channel, skipping qemu-guest-agent"
    exit 0
fi

# Install QEMU guest agent
"$YND_ROOT/scripts/tools/ensure-packages.sh" qemu-guest-agent

# Enable and start QEMU guest agent service
#systemctl enable qemu-guest-agent # apparently not needed, as it is enabled by default in Ubuntu 22.04
systemctl start qemu-guest-agent

echo "✓ QEMU Guest Agent is installed and running"