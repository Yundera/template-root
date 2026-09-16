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
        # See self-check-reboot.sh for the full rationale: skipping is correct
        # for a cron tick, and unsafe during first-run provisioning, where the
        # caller treats our exit code as "the self-check ran" and then performs
        # the irreversible SSH-key handover.
        if [ "${PCS_PROVISIONING:-0}" = "1" ]; then
            echo "Another self-check instance is running, but PCS_PROVISIONING=1 — the self-check is mandatory during provisioning. Aborting."
            exit 1
        fi
        echo "Another self-check instance is running, exiting"
        exit 0
    fi
fi

SCRIPT_DIR="/DATA/AppData/yundera/template/scripts"
source "${SCRIPT_DIR}/library/common.sh"

# BOOTSTRAP THE EXEC BITS BEFORE TRUSTING ANY SCRIPT IN THE TREE.
#
# ensure-script-executable.sh (step 2 of scripts-config.txt) exists to keep this
# tree executable, and it cannot fix the one case that matters: if the tree
# arrives mode 644, execute_script_with_logging refuses to run it —
# `[ ! -x "$script_path" ] && return 1` in library/log.sh — so the repair script
# is itself unrunnable, and so is ensure-template-sync.sh, so no later template
# can land. A box in that state never recovers without someone SSHing in.
#
# Three lines here close that paradox: we are already running, so we can always
# restore the bits before the first execute_script_with_logging call. Cheap
# (~60 files), idempotent, and it makes a whole class of delivery bug — a sync
# that loses modes, a bad umask, a restore from an archive that drops them —
# self-healing instead of terminal. wisera hit exactly this on 2026-09-16 during
# the template-subtree crossover and had to be repaired by hand.
find "$SCRIPT_DIR" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

log "=== Self-check starting ==="

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

# Run the configured list, in the configured order.
#
# `tolerate_missing=1` treats a script that is named in the config but absent on
# disk as a skip rather than a failure: it was deleted by this cycle's template
# sync, mid-run. The mirror removal on 2026-09-08 made every box in the fleet
# report two of those and end with "Self-check completed with failures", for two
# scripts that were deliberately deleted. The reconcile pass below passes 0
# instead — it re-reads the config from disk first, so a missing script there
# means the SHIPPED config names something that does not exist, which is a real
# error.
run_scripts() {
    local tolerate_missing="$1"
    shift
    local script_name
    for script_name in "$@"; do
        if [ "$tolerate_missing" = "1" ] && [ ! -f "$SCRIPT_DIR/self-check/$script_name" ]; then
            log "Skipping $script_name: listed when this run started, removed by the template sync during it"
            continue
        fi
        if ! execute_script_with_logging "$SCRIPT_DIR/self-check/$script_name"; then
            OVERALL_FAILED=1
        fi
    done
}

# Main pass: slurp the script list into memory FIRST, then iterate. This is
# deterministic even if scripts-config.txt gets replaced mid-run (e.g. by
# ensure-template-sync.sh's rsync, which atomically swaps inodes — a naive
# `while ... done < file` would keep reading the old inode via its open FD).
read_scripts_config
STARTED_WITH=("${SCRIPTS[@]}")
run_scripts 1 "${STARTED_WITH[@]}"

# Reconcile pass: ensure-template-sync.sh may have changed scripts-config.txt
# during the main pass. When it did, re-run the WHOLE list in its configured
# order rather than appending the new entries at the end.
#
# Appending was the old behaviour, and it meant a newly-delivered script ran
# after every pre-existing one for exactly one cycle — including after
# ensure-user-compose-stack-up.sh. Every ordering rule in scripts-config.txt was
# therefore false on the one cycle that mattered: the cycle that first delivers
# the script. Scripts compensated individually, by re-invoking the peers they
# had just invalidated (ensure-admin-gate-secret.sh called
# ensure-user-compose-stack-up.sh; ensure-yundera-login.sh called
# ensure-dex.sh), which made real execution order emergent instead of
# configured, and cost a bespoke workaround per ordered script. Fixing it here
# once let both of those be deleted.
#
# Re-running everything is safe by construction: these scripts are convergent
# reconcilers, that being the entire premise of the self-check. It costs one
# slow cycle, only on the rare tick that actually changes the config.
read_scripts_config
if [ "${SCRIPTS[*]}" != "${STARTED_WITH[*]}" ]; then
    log "scripts-config.txt changed during this run - re-running the full list in its configured order"
    # The complete second pass is the authoritative verdict: a script that
    # failed above only because its dependency had not run yet gets its real
    # answer here, and reporting the stale failure too would be noise.
    OVERALL_FAILED=0
    run_scripts 0 "${SCRIPTS[@]}"
fi

if [ "$OVERALL_FAILED" -eq 0 ]; then
    log "=== Self-check completed successfully ==="
else
    log "=== Self-check completed with failures ==="
fi

exit "$OVERALL_FAILED"
