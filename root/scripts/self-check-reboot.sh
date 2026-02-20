#!/bin/bash

#These scripts ensure VM basic functionalities.
#Basic functionalities are:
#1. Connectivity of the VM (VM should be accessible to the user in all cases)
#2. Docker and the admin dev stack should always be up and running
#3. The self-check script should always ensure these 3 points

set -e

MARKER_FILE="/DATA/AppData/yundera/.provisioning-in-progress"
LOCK_FILE="/var/run/yundera-self-check.lock"

# During initial provisioning, os-init.sh handles everything
# Only run from @reboot cron after provisioning is complete
if [ -f "$MARKER_FILE" ]; then
    echo "Provisioning in progress, skipping self-check (os-init.sh will handle it)"
    exit 0
fi

# Prevent concurrent execution using flock
# Lock auto-releases when process exits (cleanly or via crash/kill)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another self-check instance is running, exiting"
    exit 0
fi

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source ${SCRIPT_DIR}/library/common.sh

log "=== Self-check-os starting  ==="

# Read script configuration file and execute scripts in order
SCRIPTS_CONFIG_FILE="$SCRIPT_DIR/self-check/scripts-config.txt"

if [ ! -f "$SCRIPTS_CONFIG_FILE" ]; then
    log "ERROR: Scripts configuration file not found: $SCRIPTS_CONFIG_FILE"
    exit 1
fi

log "Reading self-check scripts from: $SCRIPTS_CONFIG_FILE"

# Read configuration file, skip comments and empty lines
while IFS= read -r script_name || [ -n "$script_name" ]; do
    # Skip comments (lines starting with #) and empty lines
    if [[ "$script_name" =~ ^[[:space:]]*# ]] || [[ -z "${script_name// }" ]]; then
        continue
    fi
    
    # Remove leading/trailing whitespace
    script_name=$(echo "$script_name" | xargs)
    
    if [ -n "$script_name" ]; then
        execute_script_with_logging "$SCRIPT_DIR/self-check/$script_name" || true
    fi
done < "$SCRIPTS_CONFIG_FILE"

# Restart the user compose stack to ensure services are in a right state
log "Restarting user compose stack"
execute_script_with_logging "$SCRIPT_DIR/tools/restart-user-compose-stack.sh" || true

log "=== Self-check-os completed successfully ==="