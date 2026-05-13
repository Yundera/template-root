#!/bin/bash

# Core self-check: runs all ensure-*.sh scripts listed in scripts-config.txt.
# Used by:
#   - the nightly cron (installed by ensure-nightly-self-check.sh)
#   - manual triggers from the admin app
#   - self-check-reboot.sh (which then also restarts the user compose stack)
#
# Exit code: 0 if every script succeeded, 1 if any failed. The loop never
# aborts early — every ensure script gets a chance to run regardless of
# earlier failures. Failures are logged via execute_script_with_logging.

set -e

MARKER_FILE="/DATA/AppData/yundera/.provisioning-in-progress"
LOCK_FILE="/var/run/yundera-self-check.lock"

# During initial provisioning, os-init.sh handles everything
if [ -f "$MARKER_FILE" ]; then
    echo "Provisioning in progress, skipping self-check (os-init.sh will handle it)"
    exit 0
fi

# Acquire the shared lock unless a parent (self-check-reboot.sh) already holds it.
if [ "${PCS_SELF_CHECK_LOCK_HELD:-0}" != "1" ]; then
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "Another self-check instance is running, exiting"
        exit 0
    fi
fi

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source "${SCRIPT_DIR}/library/common.sh"

# Provider awareness is per-script now — the four hypervisor-aware
# ensure-*.sh files call `is_proxmox_host` (from library/common.sh) to gate
# their setup. No top-level env var to resolve here.
log "=== Self-check starting (proxmox=$(is_proxmox_host && echo yes || echo no)) ==="

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

OVERALL_FAILED=0

# Main pass: slurp the script list into memory FIRST, then iterate. This is
# deterministic even if scripts-config.txt gets replaced mid-run (e.g. by
# ensure-template-sync.sh's rsync, which atomically swaps inodes — a naive
# `while ... done < file` would keep reading the old inode via its open FD).
read_scripts_config
EXECUTED=("${SCRIPTS[@]}")
for script_name in "${EXECUTED[@]}"; do
    if ! execute_script_with_logging "$SCRIPT_DIR/self-check/$script_name"; then
        OVERALL_FAILED=1
    fi
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
        if ! execute_script_with_logging "$SCRIPT_DIR/self-check/$script_name"; then
            OVERALL_FAILED=1
        fi
        EXECUTED+=("$script_name")
    fi
done

if [ "$OVERALL_FAILED" -eq 0 ]; then
    log "=== Self-check completed successfully ==="
else
    log "=== Self-check completed with failures ==="
fi

exit "$OVERALL_FAILED"
