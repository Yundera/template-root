#!/bin/bash
# Manage the nightly self-check cron entry from SELF_CHECK_CRON in .pcs.env.
#
# Behavior:
#   - SELF_CHECK_CRON unset or empty  → default "0 3 * * *" (03:00 UTC daily)
#   - SELF_CHECK_CRON="disabled"      → no nightly cron entry
#   - SELF_CHECK_CRON="<expr>"        → use that 5-field cron expression
#
# Idempotent: removes any prior entry with our marker, then writes the
# current desired entry. Safe to run on every self-check tick.

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
SCRIPT_FILE="$YND_ROOT/scripts/self-check.sh"
MARKER="# YUNDERA_NIGHTLY_SELFCHECK"

# Install cron if missing
"$YND_ROOT/scripts/tools/ensure-packages.sh" cron

chmod +x "$SCRIPT_FILE"

# Read schedule
SCHEDULE=""
if [ -f "$PCS_ENV" ]; then
    SCHEDULE=$("$ENV_MGR" get SELF_CHECK_CRON "$PCS_ENV")
fi
if [ -z "$SCHEDULE" ]; then
    SCHEDULE="0 3 * * *"
fi

# Strip any prior managed entry (lines containing our marker)
CURRENT=$(crontab -l 2>/dev/null || true)
FILTERED=$(echo "$CURRENT" | grep -vF "$MARKER" || true)

if [ "$SCHEDULE" = "disabled" ] || [ "$SCHEDULE" = "off" ]; then
    echo "Nightly self-check disabled (SELF_CHECK_CRON=$SCHEDULE)"
    printf '%s\n' "$FILTERED" | crontab -
    exit 0
fi

# Append the managed entry
NEW=$(printf '%s\n%s %s > /dev/null 2>&1 %s\n' "$FILTERED" "$SCHEDULE" "$SCRIPT_FILE" "$MARKER")
printf '%s' "$NEW" | crontab -
echo "Nightly self-check cron set to: $SCHEDULE"
