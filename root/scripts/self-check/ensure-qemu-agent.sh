#!/bin/bash

set -e

# Ensure QEMU Guest Agent Script
# This script ensures QEMU guest agent is installed and running

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Hypervisor gate — the qemu-guest-agent service needs a virtio-serial host
# channel that only Proxmox (and some bare-KVM setups) expose. Cloud
# providers like Contabo do not, so starting the service hangs and fails.
# Detection is disk-layout-based (see is_proxmox_host) — a Yundera Proxmox
# template always pairs LVM-on-/dev/sda with virtio-serial.
source "$YND_ROOT/scripts/library/common.sh"
if ! is_proxmox_host; then
    echo "→ Non-Proxmox host detected — no virtio-serial host channel, skipping qemu-guest-agent"
    exit 0
fi

# Install QEMU guest agent
"$YND_ROOT/scripts/tools/ensure-packages.sh" qemu-guest-agent

# Enable and start QEMU guest agent service
#systemctl enable qemu-guest-agent # apparently not needed, as it is enabled by default in Ubuntu 22.04
systemctl start qemu-guest-agent

echo "✓ QEMU Guest Agent is installed and running"