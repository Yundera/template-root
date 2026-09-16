#!/bin/bash

# Wait for apt locks to be released (handles cloud-init, unattended-upgrades, etc.)
# Usage: wait-for-apt-lock.sh [max_wait_seconds]
# Default: 1800 seconds (30 minutes)

max_wait=${1:-1800}
waited=0
lock_files=(
    "/var/lib/apt/lists/lock"
    "/var/lib/dpkg/lock"
    "/var/lib/dpkg/lock-frontend"
    "/var/cache/apt/archives/lock"
)

while [ $waited -lt $max_wait ]; do
    locked=false
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ] && fuser "$lock_file" >/dev/null 2>&1; then
            locked=true
            break
        fi
    done

    if [ "$locked" = false ]; then
        exit 0
    fi

    if [ $waited -eq 0 ]; then
        echo "→ Waiting for apt lock to be released..."
    fi

    sleep 5
    waited=$((waited + 5))
done

echo "⚠ Apt lock still held after ${max_wait}s, proceeding anyway..."
exit 0
