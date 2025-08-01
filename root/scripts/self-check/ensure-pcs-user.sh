#!/bin/bash

set -e

# Ensure PCS User Script
# This script ensures the 'pcs' user exists and has sudo privileges

USER_NAME="pcs"

dpkg-query -W sudo >/dev/null 2>&1 || apt-get install -qq -y sudo

# Create user if it doesn't exist
if ! id "$USER_NAME" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$USER_NAME"

    # Uncomment one of these if you need to set a password:
    # sudo passwd "$USER_NAME"  # Interactive password setting
    # echo "$USER_NAME:defaultpassword" | sudo chpasswd  # Non-interactive
fi

# Add user to sudo group if not already there
if ! groups "$USER_NAME" | grep -q "\bsudo\b"; then
    sudo usermod -aG sudo "$USER_NAME"
fi

# Ensure basic folders exist
mkdir -p /DATA/AppData/casaos/apps/yundera/scripts
mkdir -p /DATA/AppData/casaos/apps/yundera/log

touch /DATA/AppData/casaos/apps/yundera/log/yundera.log

chown -R pcs:pcs /DATA/AppData/casaos/apps/yundera/

echo "User '$USER_NAME' exist and has sudo privileges."