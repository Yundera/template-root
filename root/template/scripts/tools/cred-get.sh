#!/bin/bash

# retrieve-cred.sh - Retrieve encrypted credentials using systemd-creds
# Usage: ./retrieve-cred.sh credential-name

set -euo pipefail

CRED_DIR="/etc/credstore"
CRED_NAME="$1"
CRED_PATH="$CRED_DIR/$CRED_NAME"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <credential-name>"
    echo "Example: $0 sops-key"
    exit 1
fi

if [ ! -f "$CRED_PATH" ]; then
    echo "Error: Credential '$CRED_NAME' not found at $CRED_PATH"
    exit 1
fi

# Decrypt and output the credential
systemd-creds decrypt "$CRED_PATH"