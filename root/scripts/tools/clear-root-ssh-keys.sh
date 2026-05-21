#!/bin/bash
# Clear /root/.ssh/authorized_keys — one-shot at handover.
#
# The orchestrator seeds its create-time bootstrap ("perso") key into
# /root/.ssh/authorized_keys at VM creation (proxmox-middleware
# vm_operations/create.py — a create-path call only) and SSHes in as root
# to run pcs-init.sh. Once the PCS is handed over, all orchestrator access
# goes through the `admin` sudoer's API-sourced support key
# (ensure-yundera-support-key.sh), so root's bootstrap key is no longer
# needed and is dropped here.
#
# Deliberately a one-shot invoked from os-init.sh, NOT a recurring
# self-check: after handover the box belongs to the user, who is free to
# add their own root key — a recurring "keep /root clear" invariant would
# wipe it on the next tick.

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

ROOT_KEYS="/root/.ssh/authorized_keys"

if [ -s "$ROOT_KEYS" ]; then
    : > "$ROOT_KEYS"
    echo "Cleared $ROOT_KEYS - bootstrap key dropped; orchestrator now uses the admin support key"
fi
