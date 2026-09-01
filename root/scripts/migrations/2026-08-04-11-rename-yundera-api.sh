#!/bin/bash

# Rename YUNDERA_API -> OPERATOR_API in .pcs.env.
#
# The variable is the operator's control-plane base URL: /user/info,
# /support/ssh-key and /auth/pcs-client are all peers under it, and it is read
# by ensure-dex.sh, ensure-yundera-user-data.sh, ensure-support-key.sh and the
# admin app alike. The old name baked one operator's brand into every PCS for a
# value that is not operator-specific.
#
# Leaves YUNDERA_API in place as rollback ballast. Every consumer reads
# OPERATOR_API first and falls back to the old name, so both orders work.
#
# The predecessor rename (YUNDERA_USER_API -> YUNDERA_API, migration
# 2026-05-15-14) was deleted on 2026-09-01: it had been on stable since
# 2026-05-15, so every box has its marker.
#
# Ordering note: migrations run from ensure-template-sync.sh (#5 in
# scripts-config.txt), before ensure-env-vars-valid.sh (#17) regenerates the
# unified .env from .pcs.env — so OPERATOR_API does reach .env on this same tick.
# The admin service in docker-compose.yml still interpolates
# ${OPERATOR_API:-${YUNDERA_API:-}}, which covers any host where this migration
# has not run yet; keep it until neither name can be the only one present.

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

EXISTING=$("$ENV_MANAGER" get OPERATOR_API "$PCS_ENV_FILE" 2>/dev/null || echo "")
if [ -n "$EXISTING" ]; then
    echo "OPERATOR_API already set ($EXISTING), nothing to do"
else
    OLD=$("$ENV_MANAGER" get YUNDERA_API "$PCS_ENV_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD" ]; then
        "$ENV_MANAGER" set OPERATOR_API "$OLD" "$PCS_ENV_FILE"
        echo "Set OPERATOR_API=$OLD from YUNDERA_API"
    else
        # Neither key set: leave it that way. Each consumer already has its own
        # default, and inventing a value here would pick an operator for a host
        # that never named one.
        echo "Neither OPERATOR_API nor YUNDERA_API set, leaving as-is"
    fi
fi

echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
echo "Migration $MIGRATION_NAME completed successfully"
