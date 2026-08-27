#!/bin/bash

# Drop the `dex-internal` docker network, replaced by `yundera-auth`.
#
# Dex's gRPC client-management API used to be reached at a pinned address
# (172.31.7.2) on a /29 named `dex-internal`. That address was also the first one
# Docker's IPAM hands out dynamically, and auth-registrar shared the network with
# no pin of its own — so any cycle where auth-registrar attached while Dex was
# between restarts took Dex's address and wedged it forever on "Address already
# in use". That is what killed the 2026-08-27 demostaging2 provision.
#
# The replacement drops addressing from the design entirely: `yundera-auth` has
# no ipam block, and Dex binds gRPC to a network-scoped alias (`dex-grpc`) that
# resolves in exactly one network's DNS scope. See docker-compose.yml.
#
# Nothing here moves the containers — ensure-user-compose-stack-up.sh recreates
# them onto the new network later in this same self-check cycle, because their
# network attachments changed. This script only sweeps the empty leftover, which
# compose does not remove on `up` (project networks are torn down by `down`).
#
# ORDERING IS WHY THE MARKER IS CONDITIONAL. Migrations run from
# ensure-template-sync.sh, early — Dex and auth-registrar are still attached to
# dex-internal at this point, so the first pass cannot remove it and deliberately
# does NOT write the marker. It converges on the next cycle (nightly self-check
# or reboot), once the containers have moved. Best-effort throughout: a migration
# failure aborts template sync, and an unused empty bridge is not worth blocking
# an update over.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

OLD_NETWORK="dex-internal"

echo "Starting migration: $MIGRATION_NAME"
mkdir -p "$(dirname "$MARKER_FILE")"

if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Warning: docker not available, deferring removal of $OLD_NETWORK to a later cycle"
    exit 0
fi

if ! docker network inspect "$OLD_NETWORK" >/dev/null 2>&1; then
    echo "Network $OLD_NETWORK is already absent"
    echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
    echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
    echo "Migration $MIGRATION_NAME completed successfully"
    exit 0
fi

# Endpoints are still attached on the first pass (see the ordering note above).
# Never force them off: disconnecting a running Dex would break client
# registration until the recreate, and the recreate is minutes away anyway.
ATTACHED="$(docker network inspect "$OLD_NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
if [ -n "${ATTACHED// /}" ]; then
    echo "Network $OLD_NETWORK still has endpoints ($ATTACHED) - leaving it for a later cycle"
    exit 0
fi

if docker network rm "$OLD_NETWORK" >/dev/null 2>&1; then
    echo "Removed stale network $OLD_NETWORK"
    echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
    echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"
    echo "Migration $MIGRATION_NAME completed successfully"
else
    echo "Warning: could not remove $OLD_NETWORK, leaving it for a later cycle"
fi

exit 0
