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

# Parse scripts-config.txt into an array of script names (strips comments,
# empty lines, and surrounding whitespace).
read_scripts_config() {
    local line
    SCRIPTS=()
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        line=$(echo "$line" | xargs)
        [ -n "$line" ] && SCRIPTS+=("$line")
    done < "$SCRIPTS_CONFIG_FILE"
}

# Main pass: slurp the script list into memory FIRST, then iterate. This is
# deterministic even if scripts-config.txt gets replaced mid-run (e.g. by
# ensure-template-sync.sh's rsync, which atomically swaps inodes — a naive
# `while ... done < file` would keep reading the old inode via its open FD).
read_scripts_config
EXECUTED=("${SCRIPTS[@]}")
for script_name in "${EXECUTED[@]}"; do
    execute_script_with_logging "$SCRIPT_DIR/self-check/$script_name" || true
done

# Second pass: template-sync (or any other script) may have added new entries
# to scripts-config.txt during the main pass. Re-read and run anything we
# haven't executed yet. Ordering caveat: newly-added scripts run AFTER all
# existing ones this cycle; proper ordering takes effect on the next reboot.
read_scripts_config
for script_name in "${SCRIPTS[@]}"; do
    already_ran=false
    for ran in "${EXECUTED[@]}"; do
        [ "$ran" = "$script_name" ] && { already_ran=true; break; }
    done
    if [ "$already_ran" = false ]; then
        log "Running newly-added script from refreshed config: $script_name"
        execute_script_with_logging "$SCRIPT_DIR/self-check/$script_name" || true
        EXECUTED+=("$script_name")
    fi
done

# Restart the user compose stack to ensure services are in a right state
log "Restarting user compose stack"
execute_script_with_logging "$SCRIPT_DIR/tools/restart-user-compose-stack.sh" || true

log "=== Self-check-os completed successfully ==="