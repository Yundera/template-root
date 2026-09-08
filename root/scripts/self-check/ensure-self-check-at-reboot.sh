#!/bin/bash
# Ensure the @reboot self-check cron entry exists, and that there is exactly ONE.
#
# MANAGED BY MARKER COMMENT, like ensure-nightly-self-check.sh: strip every line
# carrying our marker, then write the entry we want. The previous version tested
# `crontab -l | grep -q "$scriptFile"` and appended when it missed, which can
# only ever add — so the root move (2026-09-08) would have left every box with
# TWO @reboot entries, the old one pointing at
# /DATA/AppData/casaos/apps/yundera. They race on
# /var/run/yundera-self-check.lock, the loser exits 0 without doing anything,
# and which tree actually converges on a given boot is a coin flip. That is the
# kind of failure nobody notices for months.
#
# The un-marked legacy line is swept explicitly below: boxes that already carry
# it were given it by the old code, which wrote no marker.
#
# RETIRE THE LEGACY SWEEP (not the marker pattern — that stays) once no box has
# an @reboot entry pointing at the old root: `sudo crontab -l | grep casaos`.
# The marker pattern alone cannot remove it, because the old code wrote no marker.

set -e  # Exit on any error

YND_ROOT="/DATA/AppData/yundera"
LEGACY_ROOT="/DATA/AppData/casaos/apps/yundera"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Install cron if crontab command is not available
"$YND_ROOT/scripts/tools/ensure-packages.sh" cron

scriptFile="$YND_ROOT/scripts/self-check-reboot.sh"
MARKER="# YUNDERA_REBOOT_SELFCHECK"
CRON_ENTRY="@reboot $scriptFile $MARKER"

# Ensure the script file is executable
chmod +x "$scriptFile"

CURRENT=$(crontab -l 2>/dev/null || true)

# Drop (a) any entry we manage, and (b) the unmarked legacy entry pointing at the
# old root. Anything else in the user's crontab is left exactly as it is.
FILTERED=$(printf '%s\n' "$CURRENT" \
    | grep -vF "$MARKER" \
    | grep -vF "@reboot $LEGACY_ROOT/scripts/self-check-reboot.sh" \
    || true)

# Both sides of the comparison below come from `$(...)`, which strips the
# trailing newline — so build DESIRED the same way rather than with a trailing
# \n, or the two can never be equal and this rewrites the crontab every tick.
if [ -n "$FILTERED" ]; then
    DESIRED=$(printf '%s\n%s' "$FILTERED" "$CRON_ENTRY")
else
    DESIRED="$CRON_ENTRY"
fi

# Only rewrite when something actually changes — `crontab -` is a full replace,
# and doing it on every tick would churn the file's mtime for nothing.
if [ "$CURRENT" = "$DESIRED" ]; then
    echo "@reboot cron job is correct"
    exit 0
fi

if printf '%s\n' "$DESIRED" | crontab -; then
    echo "@reboot cron job set to: $scriptFile"
else
    echo "ERROR: Failed to write the @reboot cron job"
    exit 1
fi
