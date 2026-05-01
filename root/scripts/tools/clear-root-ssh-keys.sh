#!/bin/bash
# Clear /root/.ssh/authorized_keys.
#
# The orchestrator (proxmox-middleware vm_operations/create.py) seeds the
# support key into /root/.ssh/authorized_keys at VM creation and never
# touches it again - copy_ssh_key_to_vm is a create-path call only. By
# the time os-init.sh calls us, ensure-admin-user.sh has already copied
# that key to /home/admin/.ssh/authorized_keys, so admin owns the support
# key going forward and root no longer needs it.

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

ROOT_KEYS="/root/.ssh/authorized_keys"

if [ -s "$ROOT_KEYS" ]; then
    : > "$ROOT_KEYS"
    echo "Cleared $ROOT_KEYS - admin user owns the support key now"
fi
