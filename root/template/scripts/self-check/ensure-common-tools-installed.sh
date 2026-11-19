#!/bin/bash
# Script to ensure common tools are installed

set -e

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"

# Install common tools
"$YND_TEMPLATE/scripts/tools/ensure-packages.sh" wget unzip rsync htop isc-dhcp-client apt-utils

echo "✓ Common tools are installed"

# Install yq (YAML processor) if not present, or if a failed download left a dud
if ! yq --version &>/dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.44.1"
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64) YQ_BINARY="yq_linux_amd64" ;;
        arm64) YQ_BINARY="yq_linux_arm64" ;;
        armhf) YQ_BINARY="yq_linux_arm" ;;
        *) echo "✗ Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    # GitHub release downloads fail now and then (seen on a staging create 2026-11-18):
    # 5 attempts with backoff, into a temp file so a failure never leaves an empty yq behind
    YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
    YQ_TMP=$(mktemp)
    installed=false
    for attempt in 1 2 3 4 5; do
        if wget -q --timeout=30 "$YQ_URL" -O "$YQ_TMP" && chmod 755 "$YQ_TMP" && "$YQ_TMP" --version &>/dev/null; then
            mv "$YQ_TMP" /usr/local/bin/yq
            installed=true
            break
        fi
        if [ "$attempt" -lt 5 ]; then
            log_warn "WARN: retry: yq download failed (attempt $attempt/5), retrying in $((attempt * 5))s"
            sleep $((attempt * 5))
        fi
    done
    rm -f "$YQ_TMP"
    if $installed; then
        echo "✓ yq installed successfully"
    else
        echo "✗ Failed to install yq from $YQ_URL"
        exit 1
    fi
else
    echo "✓ yq is already installed"
fi