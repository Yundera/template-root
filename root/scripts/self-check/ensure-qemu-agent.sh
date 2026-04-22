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
_prov="${YND_PROVIDER:-}"
if [ -z "$_prov" ] && [ -f "$YND_ROOT/.pcs.env" ]; then
    _prov="$(grep -E '^YND_PROVIDER=' "$YND_ROOT/.pcs.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
_prov="${_prov:-proxmox}"
if [ "$_prov" != "proxmox" ]; then
    echo "[YND_PROVIDER=$_prov] no virtio-serial host channel, skipping qemu-guest-agent"
    exit 0
fi

# Install QEMU guest agent
"$YND_ROOT/scripts/tools/ensure-packages.sh" qemu-guest-agent

# Enable and start QEMU guest agent service
#systemctl enable qemu-guest-agent # apparently not needed, as it is enabled by default in Ubuntu 22.04
systemctl start qemu-guest-agent

echo "✓ QEMU Guest Agent is installed and running"