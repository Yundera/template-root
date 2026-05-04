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
    echo "Another self-check instance is running, exiting"
    exit 0
fi

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source "${SCRIPT_DIR}/library/common.sh"

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
