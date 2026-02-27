#!/bin/bash

# Utility script to ensure required packages are installed
# Usage: ensure-packages.sh <package1> [package2] [package3] ...
# Example: ensure-packages.sh rsync parted bc
#
# The script will:
# - Check which packages are missing (via dpkg-query or command -v)
# - Install missing packages quietly
# - Fall back to verbose output on failure

set -e

export DEBIAN_FRONTEND=noninteractive

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ $# -eq 0 ]; then
    echo "Usage: ensure-packages.sh <package1> [package2] ..."
    exit 1
fi

# Check if a package is installed
# Uses dpkg-query for accuracy, with command fallback
is_installed() {
    local pkg="$1"

    # First try dpkg-query (works for all packages)
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        return 0
    fi

    # Fallback: check if command exists (for packages where command = package name)
    # Map package names to commands if different
    local cmd
    case "$pkg" in
        cron)           cmd="crontab" ;;
        openssh-server) cmd="sshd" ;;
        *)              cmd="$pkg" ;;
    esac

    if command -v "$cmd" &> /dev/null; then
        return 0
    fi

    return 1
}

# Build list of missing packages
PACKAGES_TO_INSTALL=""
for pkg in "$@"; do
    if ! is_installed "$pkg"; then
        PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL $pkg"
    fi
done

# Remove leading space
PACKAGES_TO_INSTALL="${PACKAGES_TO_INSTALL# }"

if [ -z "$PACKAGES_TO_INSTALL" ]; then
    # All packages already installed
    exit 0
fi

echo "→ Installing missing packages: $PACKAGES_TO_INSTALL..."

# Wait for apt lock if the helper script exists
[ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"

# Try quiet installation first
if { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y $PACKAGES_TO_INSTALL; } >/dev/null 2>&1; then
    echo "✓ Packages installed successfully"
    exit 0
fi

# Quiet install failed, retry with verbose output for debugging
echo "✗ Quiet installation failed. Retrying with verbose output..."
[ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"

if apt-get update && apt-get install -y $PACKAGES_TO_INSTALL; then
    echo "✓ Packages installed successfully"
    exit 0
else
    echo "✗ Failed to install packages: $PACKAGES_TO_INSTALL"
    exit 1
fi
