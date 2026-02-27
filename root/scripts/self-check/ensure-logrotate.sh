#!/bin/bash

set -e

# Script to ensure logrotate is configured for yundera logs

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
LOGROTATE_CONFIG="/etc/logrotate.d/yundera"
LOG_FILE="/DATA/AppData/casaos/apps/yundera/log/yundera.log"

# Ensure logrotate is installed
"$YND_ROOT/scripts/tools/ensure-packages.sh" logrotate

# Create logrotate configuration
echo "→ Configuring logrotate for yundera..."
cat > "$LOGROTATE_CONFIG" << 'EOF'
/DATA/AppData/casaos/apps/yundera/log/yundera.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 pcs pcs
    dateext
    dateformat -%Y-%m-%d
    copytruncate
}
EOF

echo "✓ Logrotate configured for yundera.log (daily rotation, 7 days retention)"
