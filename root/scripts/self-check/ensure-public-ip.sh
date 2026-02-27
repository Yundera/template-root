#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

# Ensure public IP addresses (IPv4 and IPv6) are detected and stored in environment
# Sets: PUBLIC_IP, PUBLIC_IP_DASH (main IP, prefers IPv6)
#       PUBLIC_IPV4, PUBLIC_IPV4_DASH (if available)
#       PUBLIC_IPV6, PUBLIC_IPV6_DASH (if available)
# Dash versions use - instead of . or : for nip.io compatibility

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Define the IPv6 interface name (typically ens19 - the second network device)
IPV6_INTERFACE="ens19"
NETPLAN_CONFIG="/etc/netplan/50-cloud-init.yaml"
YND_ROOT="/DATA/AppData/casaos/apps/yundera"
ENV_FILE="$YND_ROOT/.pcs.env"

# Check if IPv6 interface exists
if ! ip link show "$IPV6_INTERFACE" >/dev/null 2>&1; then
    echo "→ IPv6 interface $IPV6_INTERFACE not found. Skipping IPv6 configuration."
    exit 0
fi

# Function to check if netplan configuration has IPv6 interface properly configured
check_netplan_config() {
    if [ ! -f "$NETPLAN_CONFIG" ]; then
        return 1
    fi

    # Check if interface is defined
    if ! grep -q "^\s*$IPV6_INTERFACE:" "$NETPLAN_CONFIG" 2>/dev/null; then
        return 1
    fi

    # Check if accept-ra is enabled (required for SLAAC)
    if ! grep -A 3 "^\s*$IPV6_INTERFACE:" "$NETPLAN_CONFIG" | grep -q "accept-ra:\s*true" 2>/dev/null; then
        return 1
    fi

    return 0
}

# Configure netplan if IPv6 interface is not configured
if ! check_netplan_config; then
    # Backup existing netplan config before modification
    if [ -f "$NETPLAN_CONFIG" ]; then
        if ! cp "$NETPLAN_CONFIG" "${NETPLAN_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
            echo "✗ Failed to backup netplan configuration at $NETPLAN_CONFIG"
            echo "  Error: Unable to create backup file. Check permissions."
            exit 1
        fi
    else
        echo "✗ Netplan configuration file not found: $NETPLAN_CONFIG"
        echo "  Expected netplan config at $NETPLAN_CONFIG but file does not exist."
        exit 1
    fi

    # Add IPv6 interface configuration to netplan
    if ! cat >> "$NETPLAN_CONFIG" <<EOF
    $IPV6_INTERFACE:
      dhcp4: false
      dhcp6: false
      accept-ra: true
EOF
    then
        echo "✗ Failed to write IPv6 configuration to netplan"
        echo "  Error: Unable to append to $NETPLAN_CONFIG"
        exit 1
    fi

    # Apply netplan configuration with netplan try (safer - auto-reverts on failure)
    # Use timeout of 30 seconds and auto-confirm after 5 seconds if successful
    if ! (sleep 5 && echo) | netplan try --timeout=30 >/dev/null 2>&1; then
        echo "✗ Failed to apply netplan configuration. Running with verbose output for debugging:"
        netplan apply 2>&1 || true
        echo "  Note: Configuration may have been reverted automatically by netplan try"
        exit 1
    fi

    # Wait for SLAAC to assign address (additional time after netplan try)
    sleep 3
fi

# Ensure interface is UP
if ! ip link show "$IPV6_INTERFACE" | grep -q "state UP"; then
    # Try to bring up the interface
    if ! ip link set "$IPV6_INTERFACE" up >/dev/null 2>&1; then
        echo "✗ Failed to bring up $IPV6_INTERFACE interface. Running diagnostic:"
        echo "  Interface status:"
        ip link show "$IPV6_INTERFACE" 2>&1 || echo "  Unable to query interface"
        echo "  Attempting to bring up with verbose output:"
        ip link set "$IPV6_INTERFACE" up 2>&1 || true
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

# Try to get IPv6 address from interface
PUBLIC_IPV6=$(get_ipv6_from_interface)

# If interface method failed, try external service as fallback
if [ -z "$PUBLIC_IPV6" ]; then
    PUBLIC_IPV6=$(get_ipv6_from_external)
fi

# Update environment file with PUBLIC_IPV6
if [ -n "$PUBLIC_IPV6" ]; then
    # Create directory if it doesn't exist
    if ! mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null; then
        echo "✗ Failed to create directory for environment file"
        echo "  Directory: $(dirname "$ENV_FILE")"
        exit 1
    fi

    # Create env file if it doesn't exist
    if [ ! -f "$ENV_FILE" ]; then
        if ! touch "$ENV_FILE" 2>/dev/null; then
            echo "✗ Failed to create environment file at $ENV_FILE"
            exit 1
        fi
    fi

    # Update or add PUBLIC_IPV6 variable using unified env file manager
    if ! "$YND_ROOT/scripts/tools/env-file-manager.sh" set PUBLIC_IPV6 "$PUBLIC_IPV6" "$ENV_FILE"; then
        echo "✗ Failed to update PUBLIC_IPV6 in $ENV_FILE"
        exit 1
    fi

    # Generate dash version for nip.io (replace : with -)
    PUBLIC_IPV6_DASH=$(echo "$PUBLIC_IPV6" | tr ':' '-')
    if ! "$YND_ROOT/scripts/tools/env-file-manager.sh" set PUBLIC_IPV6_DASH "$PUBLIC_IPV6_DASH" "$ENV_FILE"; then
        echo "✗ Failed to update PUBLIC_IPV6_DASH in $ENV_FILE"
        exit 1
    fi

    echo "✓ IPv6 configured: $PUBLIC_IPV6 (dash: $PUBLIC_IPV6_DASH)"
else
    echo "→ No public IPv6 address available"
fi

# =============================================================================
# PUBLIC IPv4 DETECTION
# =============================================================================

# Get public IPv4 address via external service
get_ipv4_from_external() {
    timeout 5 curl -4 -s ident.me 2>/dev/null || echo ""
}

PUBLIC_IPV4=$(get_ipv4_from_external)

if [ -n "$PUBLIC_IPV4" ]; then
    # Update or add PUBLIC_IPV4 variable
    if ! "$YND_ROOT/scripts/tools/env-file-manager.sh" set PUBLIC_IPV4 "$PUBLIC_IPV4" "$ENV_FILE"; then
        echo "✗ Failed to update PUBLIC_IPV4 in $ENV_FILE"
        exit 1
    fi

    # Generate dash version for nip.io (replace . with -)
    PUBLIC_IPV4_DASH=$(echo "$PUBLIC_IPV4" | tr '.' '-')
    if ! "$YND_ROOT/scripts/tools/env-file-manager.sh" set PUBLIC_IPV4_DASH "$PUBLIC_IPV4_DASH" "$ENV_FILE"; then
        echo "✗ Failed to update PUBLIC_IPV4_DASH in $ENV_FILE"
        exit 1
    fi

    echo "✓ IPv4 configured: $PUBLIC_IPV4 (dash: $PUBLIC_IPV4_DASH)"
else
    echo "→ No public IPv4 address available"
fi

# =============================================================================
# PUBLIC_IP - Main public IP (uses whichever is available, prefers IPv6)
# =============================================================================

# Use IPv6 if available, otherwise fall back to IPv4, then localhost
if [ -n "$PUBLIC_IPV6" ]; then
    PUBLIC_IP="$PUBLIC_IPV6"
    PUBLIC_IP_DASH="$PUBLIC_IPV6_DASH"
elif [ -n "$PUBLIC_IPV4" ]; then
    PUBLIC_IP="$PUBLIC_IPV4"
    PUBLIC_IP_DASH="$PUBLIC_IPV4_DASH"
else
    # Default to localhost if no public IP available
    # This allows local access via custom CA certificates
    # Note: sslip.io (Let's Encrypt) won't work without a public IP
    PUBLIC_IP="127.0.0.1"
    PUBLIC_IP_DASH="127-0-0-1"
    echo "→ No public IP detected, defaulting to localhost (127.0.0.1)"
fi

if ! "$YND_ROOT/scripts/tools/env-file-manager.sh" set PUBLIC_IP "$PUBLIC_IP" "$ENV_FILE"; then
    echo "✗ Failed to update PUBLIC_IP in $ENV_FILE"
    exit 1
fi

if ! "$YND_ROOT/scripts/tools/env-file-manager.sh" set PUBLIC_IP_DASH "$PUBLIC_IP_DASH" "$ENV_FILE"; then
    echo "✗ Failed to update PUBLIC_IP_DASH in $ENV_FILE"
    exit 1
fi

echo "✓ PUBLIC_IP set to: $PUBLIC_IP (dash: $PUBLIC_IP_DASH)"
