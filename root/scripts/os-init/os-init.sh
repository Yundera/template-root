#!/bin/bash
# Ensures system is properly configured

set -e

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source ${SCRIPT_DIR}/library/common.sh

log "=== Starting final user hand over ==="

# Retry mechanism for ensure scripts with 5 retries and 20s delay
retry_script() {
    local script_path=$1
    local max_retries=5
    local retry_delay=20
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        log "Attempt $attempt of $max_retries for $script_path"
        if execute_script_with_logging "$script_path"; then
            return 0
        else
            log "Script failed on attempt $attempt"
            if [ $attempt -lt $max_retries ]; then
                log "Retrying in ${retry_delay} seconds..."
                sleep $retry_delay
            fi
        fi
        attempt=$((attempt + 1))
    done

    log "ERROR: Script $script_path failed after $max_retries attempts"
    return 1
}

# basic permission and execution setup
chmod +x $SCRIPT_DIR/self-check/ensure-pcs-user.sh
chmod +x $SCRIPT_DIR/self-check/ensure-script-executable.sh
retry_script $SCRIPT_DIR/self-check/ensure-pcs-user.sh
retry_script $SCRIPT_DIR/self-check/ensure-script-executable.sh

# Now sync template to ensure all files are up to date (after making scripts executable)
retry_script $SCRIPT_DIR/self-check/ensure-template-sync.sh;

# run small subset self-check scripts the entire subset will be run by the admin app
retry_script $SCRIPT_DIR/self-check/ensure-qemu-agent.sh
retry_script $SCRIPT_DIR/self-check/ensure-data-partition.sh
retry_script $SCRIPT_DIR/self-check/ensure-data-partition-size.sh
retry_script $SCRIPT_DIR/self-check/ensure-self-check-at-reboot.sh
retry_script $SCRIPT_DIR/self-check/ensure-docker-installed.sh

# this will generate the user specific docker compose file with user specific settings
# and run the initial start of the docker compose user stack
# This ensures the user compose stack is up to date with the latest changes
retry_script $SCRIPT_DIR/self-check/ensure-user-docker-compose-updated.sh

retry_script $SCRIPT_DIR/self-check/ensure-user-compose-pulled.sh
retry_script $SCRIPT_DIR/tools/restart-user-compose-stack.sh

# run os-init scripts only once in the VM lifecycle
execute_script_with_logging $SCRIPT_DIR/os-init/lock-password-auth.sh
execute_script_with_logging $SCRIPT_DIR/os-init/os-cleanup-before-use.sh

log "=== Final user hand over completed successfully ==="