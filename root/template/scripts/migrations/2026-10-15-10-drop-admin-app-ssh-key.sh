#!/bin/bash
# Migration: remove the admin app's own SSH key from the admin user

# Up to settings-center-app 1.x the admin app reached the host over SSH: at every
# start it minted a keypair and wrote the public half into
# /home/admin/.ssh/authorized_keys with the comment `local-admin-access`, through
# a bind mount of /home/admin/.ssh. From 2.0 it runs host actions through the
# Docker socket instead (a one-shot nsenter container, as mesh-console and
# auth-console do), and the compose file in this same tree no longer mounts
# /home/admin/.ssh. The last key the old container wrote would otherwise stay
# there for good: a root-equivalent login nothing uses any more.
#
# A MIGRATION, NOT AN ENSURE STEP: a box that pins an old 1.x image by hand
# regenerates the key at its next start, and a nightly removal would break it
# every night. This runs once, in the same sync that brings the 2.0 compose file.
# The old container keeps running without SSH until the self-check recreates it a
# few minutes later; nothing on it needs the host in between.
#
# Only lines carrying the `local-admin-access` comment go. The support key, the
# owner's keys and anything auth-console manages are left alone.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
AK="/home/admin/.ssh/authorized_keys"
MARK="local-admin-access"

echo "Starting migration: $MIGRATION_NAME"

if [ ! -f "$AK" ]; then
    echo "No $AK - nothing to remove"
    exit 0
fi
if ! grep -q "$MARK" "$AK"; then
    echo "No $MARK key in $AK"
    exit 0
fi

meta="$(stat -c '%a:%U:%G' "$AK")"
tmp="$(mktemp "$AK.XXXXXX")"
grep -v "$MARK" "$AK" > "$tmp" || true
chmod "${meta%%:*}" "$tmp"
rest="${meta#*:}"
chown "${rest%%:*}:${rest#*:}" "$tmp"
mv -f "$tmp" "$AK"

if grep -q "$MARK" "$AK"; then
    echo "Error: $MARK key still present in $AK"
    exit 1
fi
echo "Removed the admin app's $MARK key from $AK"
echo "Migration $MIGRATION_NAME completed successfully"
