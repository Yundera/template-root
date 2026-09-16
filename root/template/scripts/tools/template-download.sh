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
mkdir -p /DATA/AppData/yundera

# Download the zip file
wget "$URL" -O /tmp/yundera-template.zip

# Extract, copy, and cleanup.
#
# NOT `cp -r .../root/* /DATA/AppData/yundera/`, which is what this used to do.
# Since the subtree split (doc/template-subtree.md) the archive's top level also
# carries root/scripts/ — a compatibility shim meant only to be READ out of the
# archive by a pre-split box, never installed. Copying it would plant a legacy
# script tree on a box that should not have one, and the crossover migration
# would then keep finding it. Install the same three things
# ensure-template-sync.sh installs, and nothing else.
unzip -o /tmp/yundera-template.zip -d /tmp
SRC=$(echo /tmp/template-root-*/root)
[ -d "$SRC/template" ] || { echo "downloaded tree has no root/template/ dir" >&2; exit 1; }
mkdir -p /DATA/AppData/yundera/template
cp -r "$SRC/template/." /DATA/AppData/yundera/template/
cp "$SRC/docker-compose.yml" /DATA/AppData/yundera/
cp "$SRC/icon.svg" /DATA/AppData/yundera/.icon.svg
rm /tmp/yundera-template.zip
rm -rf /tmp/template-root-*

echo "Template downloaded and extracted successfully"

# NOTE: this script is not wired to anything (nothing in template-root,
# pcs-orchestrator or settings-center-app invokes it) and its final step used to
# run scripts/template-init.sh, which has not existed for some time — so it has
# been dead and broken independently of the split. Left working-as-far-as-it-goes
# rather than deleted, because deleting someone else's tool is their call; if it
# is genuinely unused, remove the file.
chmod +x /DATA/AppData/yundera/template/scripts/self-check.sh
/DATA/AppData/yundera/template/scripts/self-check.sh
