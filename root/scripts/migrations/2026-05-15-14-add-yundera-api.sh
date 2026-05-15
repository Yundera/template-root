#!/bin/bash

# Migrate from YUNDERA_USER_API (orchestrator-base + `/user`) to YUNDERA_API
# (bare orchestrator-base, no `/user`). The old name encoded a wrong
# abstraction — /user and /support are peers on the orchestrator, so a
# "USER_API" base couldn't reach both. New PCSes are seeded with YUNDERA_API
# directly by the orchestrator's runHostBootstrap; this migration only
# handles already-deployed hosts.
#
# Leaves YUNDERA_USER_API in place as rollback ballast (no consumer reads
# it anymore after this template push).

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"
ENV_MANAGER="$YND_ROOT/scripts/tools/env-file-manager.sh"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

EXISTING_API=$("$ENV_MANAGER" get YUNDERA_API "$PCS_ENV_FILE" 2>/dev/null || echo "")
if [ -n "$EXISTING_API" ]; then
    echo "YUNDERA_API already set ($EXISTING_API), nothing to do"
else
    OLD=$("$ENV_MANAGER" get YUNDERA_USER_API "$PCS_ENV_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD" ]; then
        # Strip trailing slash, then trailing `/user`. Tolerant of either or
        # both being absent.
        NEW="${OLD%/}"
        NEW="${NEW%/user}"
        echo "Derived YUNDERA_API=$NEW from YUNDERA_USER_API=$OLD"
    else
        NEW="https://app.yundera.com/service/pcs"
        echo "No YUNDERA_USER_API found, defaulting to $NEW"
    fi
    "$ENV_MANAGER" set YUNDERA_API "$NEW" "$PCS_ENV_FILE"
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
