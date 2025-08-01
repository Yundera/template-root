#!/bin/bash

set -e

# Script to ensure VM is configured for vertical scaling (CPU and RAM hotplug)

UDEV_RULES_FILE="/lib/udev/rules.d/80-hotplug-cpu-mem.rules"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
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