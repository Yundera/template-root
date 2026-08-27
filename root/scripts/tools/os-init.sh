#!/bin/bash
# Ensures system is properly configured

set -e

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source ${SCRIPT_DIR}/library/common.sh

log "=== Starting final user hand over ==="

# basic permission and execution setup
chmod +x $SCRIPT_DIR/self-check/ensure-pcs-user.sh
chmod +x $SCRIPT_DIR/self-check/ensure-script-executable.sh
execute_script_with_logging  $SCRIPT_DIR/self-check/ensure-pcs-user.sh
execute_script_with_logging  $SCRIPT_DIR/self-check/ensure-script-executable.sh
execute_script_with_logging "$SCRIPT_DIR/tools/generate-default-pwd.sh"

# Remove provisioning-in-progress marker so self-check-reboot.sh can run
# This also allows @reboot cron to run on subsequent boots
rm -f /DATA/AppData/yundera/.provisioning-in-progress
log "Removed provisioning-in-progress marker"

# First run the full self-check process. Export PCS_PROVISIONING so
# self-check-reboot.sh fails loud on first-run instead of masking errors
# with `|| true` (its default reboot-cron behavior, where limping is fine).
chmod +x $SCRIPT_DIR/self-check-reboot.sh
export PCS_PROVISIONING=1
execute_script_with_logging "$SCRIPT_DIR/self-check-reboot.sh"
unset PCS_PROVISIONING

# Drop the orchestrator's create-time bootstrap ("perso") key from /root.
# One-shot at handover — root SSH is only needed during provisioning.
execute_script_with_logging "$SCRIPT_DIR/tools/clear-root-ssh-keys.sh"

# Verify the SSH-key handover posture: admin must hold the API-sourced
# support key and root must hold no key.
#
# This is a final assertion, not a safety net. ensure-ssh.sh — inside the
# self-check, ~15 scripts before this point — has already applied
# `PasswordAuthentication no`, so a failure here does NOT leave the host
# password-debuggable. There is no fallback credential by design: the support
# key on admin is the only lifetime credential. What actually prevents an
# unreachable host is the precondition check inside clear-root-ssh-keys.sh
# above, which refuses to drop root's key until admin's is in place.
execute_script_with_logging "$SCRIPT_DIR/tools/verify-handover-keys.sh"

# Then run os-init specific scripts only once in the VM lifecycle
execute_script_with_logging "$SCRIPT_DIR/tools/lock-password-auth.sh"
execute_script_with_logging "$SCRIPT_DIR/tools/os-cleanup-before-use.sh"

# Install the apps this PCS ships with (PREINSTALL_APPS). One-shot like everything
# else in this block — os-init.sh running once per VM lifecycle IS the guard, which
# is why this is not a self-check: an "ensure these apps exist" tick would reinstall
# an app the user had deliberately uninstalled.
#
# Last, deliberately. It is the only step here that talks to the network, and the
# least critical thing on the box — it must not delay the irreversible SSH-key
# handover above. It always exits 0, so a store that is unreachable cannot fail a
# PCS create over a missing dashboard tile.
execute_script_with_logging "$SCRIPT_DIR/tools/preinstall-apps.sh"

log "=== Final user hand over completed successfully ==="