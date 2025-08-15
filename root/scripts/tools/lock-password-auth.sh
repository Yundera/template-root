#!/bin/bash

# Define SSH config file path
SSH_CONFIG="/etc/ssh/sshd_config"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# DockerUpdate SSH config to disable password authentication
sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#*ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#*UsePAM yes/UsePAM no/' "$SSH_CONFIG"

# Add explicit settings if they don't exist
if ! grep -q "^PasswordAuthentication no" "$SSH_CONFIG"; then
    echo "PasswordAuthentication no" >> "$SSH_CONFIG"
fi
if ! grep -q "^ChallengeResponseAuthentication no" "$SSH_CONFIG"; then
    echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG"
fi
if ! grep -q "^UsePAM no" "$SSH_CONFIG"; then
    echo "UsePAM no" >> "$SSH_CONFIG"
fi

# Restart SSH service
if systemctl restart sshd; then
    echo "SSH password authentication has been disabled. Only key-based authentication is now allowed."
else
    echo "Failed to restart SSH service. Changes may not have been applied."
    exit 1
fi