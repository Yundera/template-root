#!/bin/bash

# Do not use `set -e` — this script is best-effort: we want to record whichever
# addresses we can find even if some steps (netplan write, bringing up an
# interface, external IP service) fail. Never abort with a missing IP family —
# write what we have and continue.

export DEBIAN_FRONTEND=noninteractive

# Ensure public IP addresses (IPv4 and IPv6) are detected and stored in environment
# Sets: PUBLIC_IP, PUBLIC_IP_DASH (main IP, prefers IPv6)
#       PUBLIC_IPV4, PUBLIC_IPV4_DASH (if available)
#       PUBLIC_IPV6, PUBLIC_IPV6_DASH (if available)
# Dash versions use - instead of . or : for nip.io compatibility.

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

IPV6_INTERFACE="ens19"
NETPLAN_CONFIG="/etc/netplan/50-cloud-init.yaml"
YND_ROOT="/DATA/AppData/casaos/apps/yundera"
ENV_FILE="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null || true
[ -f "$ENV_FILE" ] || touch "$ENV_FILE" 2>/dev/null || true

set_env() {
    local key="$1"
    local value="$2"
    if ! "$ENV_MGR" set "$key" "$value" "$ENV_FILE"; then
        echo "✗ Failed to update $key in $ENV_FILE"
        return 1
    fi
}

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

get_ipv6_from_interface() {
    ip link show "$IPV6_INTERFACE" >/dev/null 2>&1 || return
    ip -6 addr show "$IPV6_INTERFACE" 2>/dev/null | \
        grep "inet6.*scope global" | \
        awk '{print $2}' | \
        cut -d'/' -f1 | \
        head -n 1
}

get_ipv6_from_external() {
    timeout 5 curl -6 -s ident.me 2>/dev/null || echo ""
}

get_ipv4_from_external() {
    timeout 5 curl -4 -s ident.me 2>/dev/null || echo ""
}

# =============================================================================
# IPv6 detection
# =============================================================================
configure_ipv6_interface
PUBLIC_IPV6=$(get_ipv6_from_interface)
[ -n "$PUBLIC_IPV6" ] || PUBLIC_IPV6=$(get_ipv6_from_external)

PUBLIC_IPV6_DASH=""
if [ -n "$PUBLIC_IPV6" ]; then
    PUBLIC_IPV6_DASH=$(echo "$PUBLIC_IPV6" | tr ':' '-')
    set_env PUBLIC_IPV6 "$PUBLIC_IPV6"
    set_env PUBLIC_IPV6_DASH "$PUBLIC_IPV6_DASH"
    echo "✓ IPv6 configured: $PUBLIC_IPV6 (dash: $PUBLIC_IPV6_DASH)"
else
    echo "→ No public IPv6 address available"
fi

# =============================================================================
# IPv4 detection — always runs, regardless of IPv6 state
# =============================================================================
PUBLIC_IPV4=$(get_ipv4_from_external)

PUBLIC_IPV4_DASH=""
if [ -n "$PUBLIC_IPV4" ]; then
    PUBLIC_IPV4_DASH=$(echo "$PUBLIC_IPV4" | tr '.' '-')
    set_env PUBLIC_IPV4 "$PUBLIC_IPV4"
    set_env PUBLIC_IPV4_DASH "$PUBLIC_IPV4_DASH"
    echo "✓ IPv4 configured: $PUBLIC_IPV4 (dash: $PUBLIC_IPV4_DASH)"
else
    echo "→ No public IPv4 address available"
fi

# =============================================================================
# PUBLIC_IP — main (prefer IPv6, then IPv4, else localhost)
# =============================================================================
if [ -n "$PUBLIC_IPV6" ]; then
    PUBLIC_IP="$PUBLIC_IPV6"
    PUBLIC_IP_DASH="$PUBLIC_IPV6_DASH"
elif [ -n "$PUBLIC_IPV4" ]; then
    PUBLIC_IP="$PUBLIC_IPV4"
    PUBLIC_IP_DASH="$PUBLIC_IPV4_DASH"
else
    # Custom CA certificates still work locally via 127.0.0.1 — sslip.io
    # (Let's Encrypt) will not, but route matching no longer silently breaks.
    PUBLIC_IP="127.0.0.1"
    PUBLIC_IP_DASH="127-0-0-1"
    echo "→ No public IP detected, defaulting to localhost (127.0.0.1)"
fi

set_env PUBLIC_IP "$PUBLIC_IP"
set_env PUBLIC_IP_DASH "$PUBLIC_IP_DASH"
echo "✓ PUBLIC_IP set to: $PUBLIC_IP (dash: $PUBLIC_IP_DASH)"
