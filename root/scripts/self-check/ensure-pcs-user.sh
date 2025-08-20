#!/bin/bash

set -e

# Ensure PCS User Script
# This script ensures the 'pcs' user exists and has sudo privileges

USER_NAME="pcs"

if ! dpkg-query -W sudo >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -qq -y sudo >/dev/null 2>&1; then
        echo "✗ Failed to install sudo. Running with verbose output for debugging:"
        apt-get install -y sudo
        exit 1
    fi
fi

# Create user if it doesn't exist
if ! id "$USER_NAME" &>/dev/null; then
    echo "→ Creating user $USER_NAME"
    useradd -m -s /bin/bash "$USER_NAME"

    # Uncomment one of these if you need to set a password:
    # passwd "$USER_NAME"  # Interactive password setting
    # echo "$USER_NAME:defaultpassword" | chpasswd  # Non-interactive
fi

# Add user to sudo group if not already there
if ! groups "$USER_NAME" | grep -q "\bsudo\b"; then
    echo "→ Adding user $USER_NAME to sudo group"
    usermod -aG sudo "$USER_NAME"
fi

# Ensure basic folders exist
mkdir -p /DATA/AppData/casaos/apps/yundera/scripts
mkdir -p /DATA/AppData/casaos/apps/yundera/log

touch /DATA/AppData/casaos/apps/yundera/log/yundera.log

chown -R pcs:pcs /DATA/AppData/casaos/apps/yundera/

echo "✓ User '$USER_NAME' exist and has sudo privileges."