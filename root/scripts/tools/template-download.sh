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

# Install dependencies
apt-get install -y wget curl unzip

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
