#!/bin/bash
# Migration: IPv4-only networkd unit with an on-link gateway on Contabo boxes

# On a Contabo VM, cloud-init's netplan config renders
# /run/systemd/network/10-netplan-eth0.network with a static IPv4, a static
# IPv6 /64 and an on-link `::/0 via fe80::1` route. With that unit, any
# networkd re-apply after boot (reload, reconfigure, restart) can fail eth0:
# "Could not set route: Nexthop has invalid gateway. Network is unreachable".
# networkd re-adds the IPv4 default route before the address it needs is back.
# On Debian 13 (systemd 257) it fails every time and eth0 stays `configuring`
# until a reboot; on Ubuntu 24.04 (255) about 1 time in 20. Every systemd
# upgrade restarts networkd from the package's postinst, and unattended-upgrades
# installs them. The kernel keeps the IPv4 config, so the box still answers,
# but DNS lookups fail at once while the link is down for networkd.
#
# The fix is the one contabo-middleware applies on every claim since 1.5.3
# (`src/provisioner/hostBaseline.ts`, which has the measurements): a copy of
# netplan's unit in /etc/systemd/network/ under the same name, which shadows
# /run, without its IPv6 lines, with IPv6 link-local and RA off and with
# `GatewayOnLink=yes`. This migration brings the boxes claimed before 1.5.3 to
# the same state. Keep the two rewrites in step.
#
# Which boxes: those whose netplan unit has Contabo's shape (the `fe80::1`
# on-link IPv6 route) and no /etc copy yet. It reads the shape of the file, not
# the provider. Every other box is left alone. Nothing on a PCS uses IPv6:
# routes register the IPv4 PUBLIC_IP, and ensure-public-ip.sh empties
# PUBLIC_IPV6 once the box has no global IPv6.
#
# It also removes the IPv4 pin that contabo-middleware 1.4.0-1.5.2 installed:
# yundera-contabo-ipv4-only.service, which wrote disable_ipv6=1 behind
# networkd's back at every boot.
#
# Applied live: `networkctl reload`, then `reconfigure` if the link is not
# `configured`. The switch from the stock unit can fail once on Ubuntu, and the
# reconfigure then runs on the new unit. Never fails the sync: a link still not
# `configured` is logged as a warning. The unit is in place, so a reboot
# configures it.

set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
PIN_UNIT="yundera-contabo-ipv4-only.service"
PIN_HELPER="/usr/local/sbin/yundera-contabo-ipv4-only"

echo "Starting migration: $MIGRATION_NAME"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping."
    exit 0
fi

if [ -f "/etc/systemd/system/$PIN_UNIT" ] || [ -f "$PIN_HELPER" ]; then
    systemctl disable "$PIN_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$PIN_UNIT" "$PIN_HELPER"
    systemctl daemon-reload
    echo "Removed the IPv4 pin ($PIN_UNIT)"
fi

IFACE=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
if [ -z "$IFACE" ]; then
    echo "No IPv4 default route - nothing to do"
    exit 0
fi
UNIT="10-netplan-$IFACE.network"
SRC="/run/systemd/network/$UNIT"
DST="/etc/systemd/network/$UNIT"

if [ ! -f "$SRC" ]; then
    echo "No netplan-rendered $UNIT - not a Contabo-shaped network, nothing to do"
    exit 0
fi
if [ -f "$DST" ]; then
    echo "$DST already exists - nothing to do"
    exit 0
fi
if ! grep -q '^Gateway=fe80::1$' "$SRC" || ! grep -q '^GatewayOnLink=' "$SRC"; then
    echo "$UNIT has no on-link fe80::1 route - not a Contabo-shaped network, nothing to do"
    exit 0
fi

awk '
function flush() { if (buf != "" && !v6) printf "%s", buf; buf = "" }
BEGIN { print "# Contabo host baseline, written by template-root migration 2026-11-23: netplan unit without IPv6." }
/^\[/ { flush(); sec = $0; buf = $0 "\n"; v6 = 0; next }
sec == "[Route]" && /^GatewayOnLink=/ { next }
sec == "[Route]" && /^(Destination|Gateway)=.*:/ { v6 = 1 }
sec == "[Route]" && /^Gateway=/ { buf = buf $0 "\nGatewayOnLink=yes\n"; next }
sec == "[Route]" { buf = buf $0 "\n"; next }
sec == "[Network]" && /^LinkLocalAddressing=/ { next }
sec == "[Network]" && /^(Address|DNS|Gateway)=.*:/ { next }
{ if (sec == "") print; else buf = buf $0 "\n" }
END { flush(); print "[Network]"; print "LinkLocalAddressing=no"; print "IPv6AcceptRA=no" }
' "$SRC" > "$DST.tmp"
if ! grep -q '^Address=[0-9.]*/' "$DST.tmp"; then
    rm -f "$DST.tmp"
    echo "Warning: no IPv4 address in $UNIT after the rewrite - left it alone"
    exit 0
fi
mv "$DST.tmp" "$DST"
echo "Wrote $DST"

state() { networkctl list "$IFACE" --no-pager --no-legend 2>/dev/null | awk '{print $5}'; }
settle() { sleep 2; for _ in $(seq 1 30); do case "$(state)" in configured|failed) return;; esac; sleep 1; done; }

networkctl reload
settle
if [ "$(state)" != configured ]; then
    echo "$IFACE is $(state) after reload - reconfiguring"
    networkctl reconfigure "$IFACE"
    settle
fi

if [ "$(state)" != configured ]; then
    echo "Warning: $IFACE is $(state) after applying the IPv4-only unit - a reboot will configure it"
elif [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
    echo "Warning: IPv6 default route still present on $IFACE"
else
    echo "$IFACE configured, IPv4 only"
fi
echo "Migration $MIGRATION_NAME completed successfully"
