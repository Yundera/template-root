#!/bin/bash

set -e

# Script to ensure VM is configured for vertical scaling (CPU and RAM hotplug)

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

UDEV_RULES_FILE="/lib/udev/rules.d/80-hotplug-cpu-mem.rules"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Provider gate — CPU/RAM hotplug is a Proxmox feature; other providers
# (Contabo monthly Storage VPS, etc.) have static resources and don't
# benefit from the udev rules or the movable_node grub flag.
_prov="${YND_PROVIDER:-}"
if [ -z "$_prov" ] && [ -f "$YND_ROOT/.pcs.env" ]; then
    _prov="$(grep -E '^YND_PROVIDER=' "$YND_ROOT/.pcs.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
_prov="${_prov:-proxmox}"
if [ "$_prov" != "proxmox" ]; then
    echo "[YND_PROVIDER=$_prov] static resources, skipping hotplug setup"
    exit 0
fi

# Create rules directory if it doesn't exist
mkdir -p /lib/udev/rules.d/

# Create udev hotplug rules
cat > "$UDEV_RULES_FILE" << EOF
SUBSYSTEM=="cpu", ACTION=="add", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
SUBSYSTEM=="memory", ACTION=="add", TEST=="state", ATTR{state}=="offline", ATTR{state}="online"
EOF

# Add movable_node to GRUB if not already present
if ! grep -q "movable_node" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 movable_node"/' /etc/default/grub
    update-grub
fi

echo "VM hotplug configuration ensured: CPU and RAM can be dynamically added or removed."