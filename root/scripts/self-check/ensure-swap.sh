#!/bin/bash

set -e

# Script to ensure swap is configured properly

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

SWAP_FILE="/swap.img"
SWAP_SIZE="4G"
SWAPPINESS_VALUE="10"

# Create swap file if it doesn't exist
if [ ! -f "$SWAP_FILE" ]; then
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
fi

# Activate swap if not already active
if ! swapon --show | grep -q "$SWAP_FILE"; then
    swapon "$SWAP_FILE"
fi

# Add to fstab if not already there
if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

# Set swappiness
sysctl vm.swappiness="$SWAPPINESS_VALUE" > /dev/null

# Make swappiness persistent
if ! grep -q "vm.swappiness=$SWAPPINESS_VALUE" /etc/sysctl.conf; then
    echo "vm.swappiness=$SWAPPINESS_VALUE" >> /etc/sysctl.conf
fi

echo "Swap configuration ensured: $SWAP_FILE with size $SWAP_SIZE and swappiness set to $SWAPPINESS_VALUE."