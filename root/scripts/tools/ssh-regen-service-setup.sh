#!/bin/bash

# Script to set up SSH host key regeneration service
# This service will regenerate SSH host keys on boot if they don't exist

set -euo pipefail

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)" >&2
    exit 1
fi

# Define service file path and content
SERVICE_FILE="/etc/systemd/system/regenerate_ssh_host_keys.service"
SERVICE_NAME="regenerate_ssh_host_keys.service"

# Create the systemd service file
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Regenerate SSH host keys on boot if they don't exist
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if ! ls /etc/ssh/ssh_host_*_key 1> /dev/null 2>&1; then echo "No SSH host keys found, regenerating..."; /usr/sbin/dpkg-reconfigure -f noninteractive openssh-server; else echo "SSH host keys already exist, skipping regeneration"; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Set proper permissions for the service file
chmod 644 "$SERVICE_FILE"

# Reload systemd to recognize the new service
systemctl daemon-reload

# Enable the service to run on boot
systemctl enable "$SERVICE_NAME"

# Check if the service was enabled successfully
if systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
    echo "✓ Setting up SSH host key regeneration service successfully set up ($SERVICE_FILE)"
else
    echo "✗ Failed to enable service" >&2
    exit 1
fi

echo "Service status:"
systemctl status "$SERVICE_NAME" --no-pager || true