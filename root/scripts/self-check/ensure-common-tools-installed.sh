#!/bin/bash
# Script to ensure common tools are installed
export DEBIAN_FRONTEND=noninteractive

if ! apt-get install -qq -y wget unzip rsync htop isc-dhcp-client apt-utils >/dev/null 2>&1; then
    echo "✗ Failed to install common tools. Running with verbose output for debugging:"
    apt-get install -y wget unzip rsync htop isc-dhcp-client apt-utils
    exit 1
fi

echo "✓ Common tools are installed"