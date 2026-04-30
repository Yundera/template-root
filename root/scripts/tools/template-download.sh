#!/bin/bash
# Downloads and installs the Yundera template from GitHub
# Usage: template-download.sh [main|stable|<custom-url>]

set -e

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Parse argument
SOURCE="${1:-stable}"

case "$SOURCE" in
    main)
        URL="https://github.com/Yundera/template-root/archive/refs/heads/main.zip"
        echo "Downloading template from main branch..."
        ;;
    stable)
        URL="https://github.com/Yundera/template-root/archive/refs/heads/stable.zip"
        echo "Downloading template from stable branch..."
        ;;
    http*|https*)
        URL="$SOURCE"
        echo "Downloading template from custom URL: $URL"
        ;;
    *)
        echo "Usage: $0 [main|stable|<custom-url>]"
        echo ""
        echo "Options:"
        echo "  main    - Download from main branch (latest development)"
        echo "  stable  - Download from stable branch (default)"
        echo "  <url>   - Download from a custom URL (e.g., https://github.com/Yundera/template-root/archive/refs/tags/v1.1.0.zip)"
        exit 1
        ;;
esac

# Install dependencies. Wait for cloud-init / unattended-upgrades to release
# the apt lock first, and retry on transient lock contention. The helper
# script wait-for-apt-lock.sh isn't on disk yet (it ships in the template
# we're about to download), so this lock check is inlined.
APT_LOCKS=(
    /var/lib/apt/lists/lock
    /var/lib/dpkg/lock
    /var/lib/dpkg/lock-frontend
    /var/cache/apt/archives/lock
)
wait_apt_lock() {
    local max=${1:-300} waited=0 f
    while [ "$waited" -lt "$max" ]; do
        local locked=0
        for f in "${APT_LOCKS[@]}"; do
            if [ -f "$f" ] && fuser "$f" >/dev/null 2>&1; then
                locked=1
                break
            fi
        done
        [ "$locked" -eq 0 ] && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}
apt_run() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then return 0; fi
        echo "apt attempt $attempt failed, waiting for lock and retrying..."
        wait_apt_lock 300 || true
    done
    return 1
}
export DEBIAN_FRONTEND=noninteractive
wait_apt_lock 300 || echo "apt lock still held after 5min, proceeding anyway"
apt_run apt-get install -y wget curl unzip

# Create target directory
mkdir -p /DATA/AppData/casaos/apps/yundera

# Download the zip file
wget "$URL" -O /tmp/yundera-template.zip

# Extract, copy, and cleanup
unzip -o /tmp/yundera-template.zip -d /tmp
cp -r /tmp/template-root-*/root/* /DATA/AppData/casaos/apps/yundera/
rm /tmp/yundera-template.zip
rm -rf /tmp/template-root-*

echo "Template downloaded and extracted successfully"

# Execute the init script
chmod +x /DATA/AppData/casaos/apps/yundera/scripts/template-init.sh
/DATA/AppData/casaos/apps/yundera/scripts/template-init.sh
