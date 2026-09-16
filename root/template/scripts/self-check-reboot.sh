#!/bin/bash

# Reboot self-check: runs the core self-check, then restarts the user compose
# stack so services come up cleanly after host startup. Installed as an
# @reboot cron entry by ensure-self-check-at-reboot.sh.
#
# The lock is acquired here and held across both the self-check and the
# compose restart, so a manual run cannot race with reboot-time bring-up.

set -e

MARKER_FILE="/DATA/AppData/yundera/.provisioning-in-progress"
LOCK_FILE="/var/run/yundera-self-check.lock"

# During initial provisioning, os-init.sh handles everything
if [ -f "$MARKER_FILE" ]; then
    echo "Provisioning in progress, skipping self-check-reboot (os-init.sh will handle it)"
    exit 0
fi

# Hold the lock for the entire reboot sequence (self-check + compose restart).
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    # Contention is a routine no-op on the @reboot/nightly path — another
    # instance is already doing the work, and skipping is correct.
    #
    # It is NEVER acceptable during first-run provisioning. os-init.sh reads
    # our exit code as "the self-check ran"; on exit 0 it proceeds to the
    # irreversible handover (clear-root-ssh-keys.sh) having never created the
    # admin user or installed the support key. That is exactly how a demo PCS
    # was bricked on 2026-08-23 when two pcs-init.sh runs raced on one host.
    # Fail loud instead, so os-init.sh's `set -e` aborts and the orchestrator
    # routes to onCreateFailure rather than waiting 90 min in
    # waitForDomainReady.
    if [ "${PCS_PROVISIONING:-0}" = "1" ]; then
        echo "Another self-check instance is running, but PCS_PROVISIONING=1 — the self-check is mandatory during provisioning. Aborting."
        exit 1
    fi
    echo "Another self-check instance is running, exiting"
    exit 0
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

# Run the core self-check with the lock-bypass flag so it doesn't try to
# re-acquire the lock we already hold. On the @reboot cron path, failures
# don't abort — we still want to bring the user compose stack up on a
# degraded host. During first-run provisioning (PCS_PROVISIONING=1, set
# by os-init.sh), failures DO abort: the orchestrator's runHostBootstrap
# needs a non-zero exit so it can route to onCreateFailure immediately
# instead of waiting 90 min on waitForDomainReady.
if [ "${PCS_PROVISIONING:-0}" = "1" ]; then
    PCS_SELF_CHECK_LOCK_HELD=1 "$SCRIPT_DIR/self-check.sh"
    log "Restarting user compose stack (provisioning: fail-fast on errors)"
    execute_script_with_logging "$SCRIPT_DIR/tools/restart-user-compose-stack.sh"
else
    PCS_SELF_CHECK_LOCK_HELD=1 "$SCRIPT_DIR/self-check.sh" || true
    log "Restarting user compose stack (reboot: best-effort, errors masked)"
    execute_script_with_logging "$SCRIPT_DIR/tools/restart-user-compose-stack.sh" || true
fi
