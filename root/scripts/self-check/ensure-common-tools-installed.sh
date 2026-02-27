#!/bin/bash
# Script to ensure common tools are installed

set -e

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

# Install common tools
"$YND_ROOT/scripts/tools/ensure-packages.sh" wget unzip rsync htop isc-dhcp-client apt-utils

echo "✓ Common tools are installed"

# Install yq (YAML processor) if not present
if ! command -v yq &>/dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.44.1"
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64) YQ_BINARY="yq_linux_amd64" ;;
        arm64) YQ_BINARY="yq_linux_arm64" ;;
        armhf) YQ_BINARY="yq_linux_arm" ;;
        *) echo "✗ Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    if wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O /usr/local/bin/yq; then
        chmod +x /usr/local/bin/yq
        echo "✓ yq installed successfully"
    else
        echo "✗ Failed to install yq"
        exit 1
    fi
else
    echo "✓ yq is already installed"
fi