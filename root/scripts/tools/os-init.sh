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

# Verify the SSH-key handover posture before locking the box down: admin
# must hold the API-sourced support key and root must hold no key. Runs
# before lock-password-auth.sh so a failure leaves the box still
# debuggable (password auth not yet disabled).
execute_script_with_logging "$SCRIPT_DIR/tools/verify-handover-keys.sh"

# Then run os-init specific scripts only once in the VM lifecycle
execute_script_with_logging "$SCRIPT_DIR/tools/lock-password-auth.sh"
execute_script_with_logging "$SCRIPT_DIR/tools/os-cleanup-before-use.sh"

log "=== Final user hand over completed successfully ==="