#!/bin/bash

set -e

# Prefer IPv4 over IPv6 in glibc's getaddrinfo() for dual-stack destinations.
#
# Reason: GitHub Container Registry (pkg-containers.githubusercontent.com)
# is served by two different CDN backends depending on address family:
#   IPv4 → Fastly (reliable)
#   IPv6 → Azure-hosted GitHub blob storage (sends random TCP RSTs mid-stream,
#          stalls on docker pulls)
# Observed on Contabo PCS: provisioning stuck 30+ minutes retrying GHCR
# pulls over v6 while the underlying network path is clean (mtr shows 0%
# loss, ping6 RTT <5ms). The bytes just don't flow reliably at the TLS/HTTP
# layer because the v6 backend itself is flaky.
#
# Fix: set `precedence ::ffff:0:0/96 100` in /etc/gai.conf so the IPv4-mapped
# range outranks every IPv6 range. getaddrinfo() then returns IPv4 first for
# dual-stack hostnames; v6-only destinations are unaffected.
#
# Applies on all providers: Scaleway only needs IPv6 for the inbound bind
# (handled by ensure-public-ip.sh), never for outbound.

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

GAI_CONF="/etc/gai.conf"
TARGET_LINE="precedence ::ffff:0:0/96  100"

if [ ! -f "$GAI_CONF" ]; then
    touch "$GAI_CONF"
fi

# Already active with the right value — nothing to do.
if grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100[[:space:]]*$' "$GAI_CONF"; then
    exit 0
fi

# Existing active line with a different value — overwrite.
if grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+[0-9]+[[:space:]]*$' "$GAI_CONF"; then
    sed -i -E 's|^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+[0-9]+[[:space:]]*$|precedence ::ffff:0:0/96  100|' "$GAI_CONF"
    echo "✓ Updated $GAI_CONF: precedence ::ffff:0:0/96 → 100 (prefer IPv4)"
    exit 0
fi

# Not present at all — append. Trailing newline already on file is fine;
# we add our own leading newline for separation from prior content.
printf '\n# Prefer IPv4 for dual-stack destinations — GHCR/Azure IPv6 path is unreliable.\n# See ensure-outbound-ip-family.sh for context.\n%s\n' "$TARGET_LINE" >> "$GAI_CONF"
echo "✓ Added to $GAI_CONF: $TARGET_LINE (prefer IPv4)"
