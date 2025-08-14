#!/bin/bash

# store-cred.sh - Store encrypted credentials using systemd-creds
# Usage: 
#   echo "secret" | ./store-cred.sh credential-name
#   ./store-cred.sh credential-name "secret-value"

set -euo pipefail

CRED_DIR="/etc/credstore"
CRED_NAME="$1"
CRED_PATH="$CRED_DIR/$CRED_NAME"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <credential-name> [secret-value]"
    echo "  If secret-value is not provided, it will be read from stdin"
    echo "Examples:"
    echo "  echo 'my-secret' | $0 sops-key"
    echo "  $0 sops-key 'my-secret'"
    exit 1
fi

# Create credential directory if it doesn't exist
sudo mkdir -p "$CRED_DIR"

if [ $# -eq 2 ]; then
    # Secret provided as argument
    echo "$2" | sudo systemd-creds encrypt --pretty - "$CRED_PATH"
else
    # Read secret from stdin
    sudo systemd-creds encrypt --pretty - "$CRED_PATH"
fi

echo "Credential '$CRED_NAME' stored successfully at $CRED_PATH"