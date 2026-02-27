#!/bin/bash
# Script to ensure @reboot cron job is configured

set -e  # Exit on any error

export DEBIAN_FRONTEND=noninteractive

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Install cron if crontab command is not available
if ! command -v crontab &> /dev/null; then
    echo "→ Installing cron..."
    [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
    if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y cron; } >/dev/null 2>&1; then
        echo "✗ Failed to install cron. Running with verbose output for debugging:"
        [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
        apt-get update && apt-get install -y cron
        exit 1
    fi
fi

remoteFolder="/DATA/AppData/casaos/apps/yundera/scripts"
scriptFile="$remoteFolder/self-check-reboot.sh"
CRON_ENTRY="@reboot $scriptFile"

# Ensure the script file is executable
chmod +x "$scriptFile"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "$scriptFile"; then
    echo "@reboot cron job exists"
else
    echo "Adding @reboot cron job for start.sh"

    # Add the cron job
    if (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_ENTRY"; } | crontab -; then
        echo "@reboot cron job added successfully"
    else
        echo "ERROR: Failed to add @reboot cron job"
        exit 1
    fi
fi