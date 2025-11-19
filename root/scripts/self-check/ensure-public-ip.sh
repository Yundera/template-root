#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

# Ensure public IP addresses (IPv4 and IPv6) are detected and stored in environment
# Currently implements IPv6 detection - IPv4 detection will be added in future updates

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Define the IPv6 interface name (typically ens19 - the second network device)
IPV6_INTERFACE="ens19"
NETPLAN_CONFIG="/etc/netplan/50-cloud-init.yaml"
ENV_FILE="/DATA/AppData/casaos/apps/yundera/.ynd.user.env"

# Check if IPv6 interface exists
if ! ip link show "$IPV6_INTERFACE" >/dev/null 2>&1; then
    echo "→ IPv6 interface $IPV6_INTERFACE not found. Skipping IPv6 configuration."
    exit 0
fi

# Function to check if netplan configuration has IPv6 interface
check_netplan_config() {
    if [ ! -f "$NETPLAN_CONFIG" ]; then
        return 1
    fi

    if grep -q "^\s*$IPV6_INTERFACE:" "$NETPLAN_CONFIG" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Configure netplan if IPv6 interface is not configured
if ! check_netplan_config; then
    echo "→ Configuring $IPV6_INTERFACE in netplan..."

    # Backup existing netplan config
    if [ -f "$NETPLAN_CONFIG" ]; then
        cp "$NETPLAN_CONFIG" "${NETPLAN_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    # Add IPv6 interface configuration
    if [ -f "$NETPLAN_CONFIG" ]; then
        # Check if we need to add the interface
        if ! grep -q "^\s*$IPV6_INTERFACE:" "$NETPLAN_CONFIG"; then
            # Add the interface configuration under ethernets section
            if grep -q "^\s*ethernets:" "$NETPLAN_CONFIG"; then
                # Insert after the last ethernet interface definition
                cat >> "$NETPLAN_CONFIG" <<EOF
    $IPV6_INTERFACE:
      dhcp4: false
      dhcp6: false
      accept-ra: true
EOF
            fi
        fi
    fi

    # Apply netplan configuration
    if ! netplan apply >/dev/null 2>&1; then
        echo "✗ Failed to apply netplan configuration. Running with verbose output:"
        netplan apply
        exit 1
    fi

    # Wait for interface to come up
    sleep 3
fi

# Check if interface is UP
if ! ip link show "$IPV6_INTERFACE" | grep -q "state UP"; then
    echo "→ Bringing up $IPV6_INTERFACE interface..."
    if ! ip link set "$IPV6_INTERFACE" up >/dev/null 2>&1; then
        echo "✗ Failed to bring up $IPV6_INTERFACE interface"
        exit 1
    fi
    # Wait for SLAAC to assign address
    sleep 5
fi

# Get public IPv6 address from interface
get_ipv6_from_interface() {
    # Get global scope IPv6 address (not link-local fe80::)
    ip -6 addr show "$IPV6_INTERFACE" 2>/dev/null | \
        grep "inet6.*scope global" | \
        awk '{print $2}' | \
        cut -d'/' -f1 | \
        head -n 1
}

# Get public IPv6 address via external service (fallback)
get_ipv6_from_external() {
    timeout 5 curl -6 -s ident.me 2>/dev/null || echo ""
}

# Try to get IPv6 address
PUBLIC_IPV6=$(get_ipv6_from_interface)

# If interface method failed, try external service
if [ -z "$PUBLIC_IPV6" ]; then
    echo "→ No IPv6 address found on interface. Trying external detection..."
    PUBLIC_IPV6=$(get_ipv6_from_external)
fi

# Update environment file with PUBLIC_IPV6
if [ -n "$PUBLIC_IPV6" ]; then
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$ENV_FILE")"

    # Create env file if it doesn't exist
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
    fi

    # Update or add PUBLIC_IPV6 variable
    if grep -q "^PUBLIC_IPV6=" "$ENV_FILE" 2>/dev/null; then
        # Update existing entry
        sed -i "s|^PUBLIC_IPV6=.*|PUBLIC_IPV6=$PUBLIC_IPV6|" "$ENV_FILE"
    else
        # Add new entry
        echo "PUBLIC_IPV6=$PUBLIC_IPV6" >> "$ENV_FILE"
    fi

    echo "✓ IPv6 network configured. Public IPv6: $PUBLIC_IPV6"
else
    echo "→ No public IPv6 address available. This is normal if IPv6 is not configured on this cluster."
fi
