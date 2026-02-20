#!/bin/bash
# Script to ensure common tools are installed
export DEBIAN_FRONTEND=noninteractive

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

[ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
if ! apt-get install -qq -y wget unzip rsync htop isc-dhcp-client apt-utils >/dev/null 2>&1; then
    echo "✗ Failed to install common tools. Running with verbose output for debugging:"
    [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
    apt-get install -y wget unzip rsync htop isc-dhcp-client apt-utils
    exit 1
fi

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