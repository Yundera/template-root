#!/bin/bash

#These scripts ensure VM basic functionalities.
#Basic functionalities are:
#1. Connectivity of the VM (VM should be accessible to the user in all cases)
#2. Docker and the admin dev stack should always be up and running
#3. The self-check script should always ensure these 3 points

set -e

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source ${SCRIPT_DIR}/library/common.sh

log "=== Self-check-os starting  ==="

# Make scripts executable first, then sync template to ensure all files are up to date
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-script-executable.sh
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-template-sync.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-user-data.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-self-check-at-reboot.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-docker-installed.sh;
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-user-docker-compose-updated.sh;
# This ensures the user compose stack is up to date with the latest changes
execute_script_with_logging $SCRIPT_DIR/self-check/ensure-user-compose-pulled.sh;

#restart the user compose stack to ensure service are in a right state for example casaos only works well after a fresh down and up
execute_script_with_logging $SCRIPT_DIR/tools/restart-user-compose-stack.sh

log "=== Self-check-os completed successfully ==="