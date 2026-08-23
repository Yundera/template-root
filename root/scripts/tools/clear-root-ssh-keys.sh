#!/bin/bash
# Clear /root/.ssh/authorized_keys — one-shot at handover.
#
# The orchestrator seeds its create-time bootstrap ("perso") key into
# /root/.ssh/authorized_keys at VM creation (proxmox-middleware
# vm_operations/create.py — a create-path call only) and SSHes in as root
# to run pcs-init.sh. Once the PCS is handed over, all orchestrator access
# goes through the `admin` sudoer's API-sourced support key
# (ensure-support-key.sh), so root's bootstrap key is no longer
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
ADMIN_KEYS="/home/admin/.ssh/authorized_keys"

# Precondition: the replacement credential must already exist.
#
# This is the only irreversible step in provisioning — everything else can be
# retried. ensure-support-key.sh already aborts the self-check when it cannot
# install the support key, but that only protects the host if the failure
# propagates all the way up through self-check.sh → self-check-reboot.sh →
# execute_script_with_logging → os-init.sh's `set -e`. On 2026-08-23 that chain
# broke (lock contention returned exit 0, which os-init.sh read as success) and
# this script wiped root's key on a host where `admin` had never been created.
# The result was a host with no root key, no support key, and password auth
# already disabled by ensure-ssh.sh — unreachable, unrecoverable.
#
# Checking the precondition here is invariant to that entire chain.
if [ ! -s "$ADMIN_KEYS" ]; then
    echo "✗ $ADMIN_KEYS missing or empty — refusing to clear root's bootstrap key."
    echo "  Dropping it now would leave this host with no way in at all."
    echo "  ensure-admin-user.sh and ensure-support-key.sh must succeed first."
    exit 1
fi

if [ -s "$ROOT_KEYS" ]; then
    : > "$ROOT_KEYS"
    echo "Cleared $ROOT_KEYS - bootstrap key dropped; orchestrator now uses the admin support key"
fi
