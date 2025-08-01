#!/bin/bash

# Fetch reference template from GitHub and copy to local template folder

GITHUB_URL="https://raw.githubusercontent.com/Yundera/settings-center-app/main/template-setup/root/compose-template.yml"
COMPOSE_FILE="/DATA/AppData/casaos/apps/yundera/compose-template.yml"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$COMPOSE_FILE")"

# Download and copy template
echo "Downloading template from GitHub..."
wget -O "$COMPOSE_FILE" "$GITHUB_URL"

if [ $? -eq 0 ]; then
    echo "Template updated successfully"
else
    echo "Error: Failed to download template"
    exit 1
fi