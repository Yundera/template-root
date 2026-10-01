#!/bin/bash
# ensure-ipv6-interface.sh - Bring up the provider's IPv6 interface (ens19).
#
# Host preparation, and the only part of the former ensure-public-ip.sh that is
# Yundera's: some providers hand a VM its IPv6 on a second interface that
# cloud-init leaves unconfigured. This adds a router-advertisement stanza for it
# to netplan and brings it up, so the address is there for the mesh template's
# own ensure-public-ip.sh (PUBLIC_IP_MODE=interface) to find. Detecting and
# probing the public addresses is the mesh template's job now; this template
# reads them back from the mesh .env (library/mesh.sh).
#
# ORDERING: before ensure-mesh-installed.sh, whose first mesh run detects the
# addresses.
#
# Best-effort, never fails the self-check: a box without the interface, or with
# a netplan that will not take the stanza, still has its IPv4.

export DEBIAN_FRONTEND=noninteractive

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

IPV6_INTERFACE="ens19"
NETPLAN_CONFIG="/etc/netplan/50-cloud-init.yaml"

# Configure the IPv6 interface if present (netplan + bring up). Each step is
# best-effort; failures are logged but never abort the script.
configure_ipv6_interface() {
    if ! ip link show "$IPV6_INTERFACE" >/dev/null 2>&1; then
        echo "→ IPv6 interface $IPV6_INTERFACE not found. Skipping IPv6 interface configuration."
        return
    fi

    local needs_netplan=0
    if [ ! -f "$NETPLAN_CONFIG" ]; then
        echo "→ Netplan config $NETPLAN_CONFIG not found. Skipping netplan setup."
    elif ! grep -q "^\s*$IPV6_INTERFACE:" "$NETPLAN_CONFIG" 2>/dev/null \
         || ! grep -A 3 "^\s*$IPV6_INTERFACE:" "$NETPLAN_CONFIG" | grep -q "accept-ra:\s*true" 2>/dev/null; then
        needs_netplan=1
    fi

    if [ "$needs_netplan" = 1 ]; then
        if ! cp "$NETPLAN_CONFIG" "${NETPLAN_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
            echo "→ Failed to back up $NETPLAN_CONFIG; skipping netplan write"
        elif ! cat >> "$NETPLAN_CONFIG" <<EOF
    $IPV6_INTERFACE:
      dhcp4: false
      dhcp6: false
      accept-ra: true
EOF
        then
            echo "→ Failed to append IPv6 config to netplan; continuing"
        else
            if ! (sleep 5 && echo) | netplan try --timeout=30 >/dev/null 2>&1; then
                echo "→ netplan try failed; falling back to netplan apply"
                netplan apply >/dev/null 2>&1 || echo "→ netplan apply also failed; continuing"
            fi
            sleep 3
        fi
    fi

    if ! ip link show "$IPV6_INTERFACE" | grep -q "state UP"; then
        if ip link set "$IPV6_INTERFACE" up >/dev/null 2>&1; then
            sleep 5
        else
            echo "→ Could not bring $IPV6_INTERFACE up; continuing"
        fi
    fi
}

configure_ipv6_interface
exit 0
