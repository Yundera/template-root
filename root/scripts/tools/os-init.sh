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

# First run the full self-check process
chmod +x $SCRIPT_DIR/self-check-reboot.sh
execute_script_with_logging "$SCRIPT_DIR/self-check-reboot.sh"

# Then run os-init specific scripts only once in the VM lifecycle
execute_script_with_logging "$SCRIPT_DIR/tools/lock-password-auth.sh"
execute_script_with_logging "$SCRIPT_DIR/tools/os-cleanup-before-use.sh"

log "=== Final user hand over completed successfully ==="