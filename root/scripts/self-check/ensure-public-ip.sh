#!/bin/bash

# Do not use `set -e` — this script is best-effort: we want to record whichever
# addresses we can find even if some steps (netplan write, bringing up an
# interface, external IP service, backend probe) fail. Never abort with a
# missing IP family — write what we have and continue.

export DEBIAN_FRONTEND=noninteractive

# Ensure public IP addresses (IPv4 and IPv6) are detected, verified reachable
# from the public internet, and stored in the env file.
#
# Sets: PUBLIC_IP, PUBLIC_IP_DASH (canonical, prefers IPv4 when both probe-reachable)
#       PUBLIC_IPV4, PUBLIC_IPV4_DASH (only when probe-reachable)
#       PUBLIC_IPV6, PUBLIC_IPV6_DASH (only when probe-reachable)
# Dash versions use - instead of . or : for nip.io compatibility.
#
# Reachability probe is delegated to mesh-router-backend's /probe endpoint
# (ICMP from the backend's vantage point). This catches the failure mode
# where an IP is bound to a local interface but isn't routed externally —
# previously, such IPs were registered and silently broke routing.

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

IPV6_INTERFACE="ens19"
NETPLAN_CONFIG="/etc/netplan/50-cloud-init.yaml"
YND_ROOT="/DATA/AppData/casaos/apps/yundera"
ENV_FILE="$YND_ROOT/.pcs.env"
USER_ENV_FILE="$YND_ROOT/.ynd.user.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
PROBE_PATH="/router/api/probe"
PROBE_TIMEOUT_SECONDS=8

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

# Derive the mesh-router-backend probe URL from the user's DOMAIN.
# DOMAIN=alice.nsl.sh         -> https://nsl.sh/router/api/probe
# DOMAIN=wisera.inojob.com    -> https://inojob.com/router/api/probe
# Returns empty string if DOMAIN is not set or doesn't have a server suffix.
derive_probe_url() {
    local domain=""
    if [ -f "$USER_ENV_FILE" ]; then
        domain=$(grep -E '^DOMAIN=' "$USER_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi
    if [ -z "$domain" ] || [ "${domain#*.}" = "$domain" ]; then
        echo ""
        return
    fi
    echo "https://${domain#*.}${PROBE_PATH}"
}

# Calls /probe with up to two candidate IPs and returns the list of UNREACHABLE
# IPs on stdout, one per line. On any failure (probe endpoint missing, network
# error, malformed response) returns nothing — the caller treats that as
# "trust local detection" so we never make probing a hard dependency.
get_unreachable_ips() {
    local probe_url="$1"
    shift
    local candidates=("$@")
    [ -z "$probe_url" ] && return
    [ "${#candidates[@]}" -eq 0 ] && return

    local payload="{\"candidates\":["
    local first=1
    for ip in "${candidates[@]}"; do
        [ -z "$ip" ] && continue
        if [ "$first" = 1 ]; then
            first=0
        else
            payload+=","
        fi
        payload+="\"$ip\""
    done
    payload+="]}"

    local response
    response=$(timeout "$PROBE_TIMEOUT_SECONDS" curl -sS \
        --max-time "$PROBE_TIMEOUT_SECONDS" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$probe_url" 2>/dev/null) || return

    [ -z "$response" ] && return

    if ! command -v python3 >/dev/null 2>&1; then
        return
    fi

    python3 - <<PY 2>/dev/null
import json, sys
try:
    data = json.loads('''$response''')
except Exception:
    sys.exit(0)
results = data.get("results")
if not isinstance(results, list):
    sys.exit(0)
for r in results:
    if isinstance(r, dict) and r.get("reachable") is False and r.get("ip"):
        print(r["ip"])
PY
}

# =============================================================================
# IPv6 detection
# =============================================================================
configure_ipv6_interface
PUBLIC_IPV6=$(get_ipv6_from_interface)
[ -n "$PUBLIC_IPV6" ] || PUBLIC_IPV6=$(get_ipv6_from_external)

# =============================================================================
# IPv4 detection — always runs, regardless of IPv6 state
# =============================================================================
PUBLIC_IPV4=$(get_ipv4_from_external)

# =============================================================================
# Reachability probe — ask mesh-router-backend to verify each detected IP
# from its public vantage point. Unset any IP that doesn't respond to ICMP.
# =============================================================================
PROBE_URL=$(derive_probe_url)
if [ -n "$PROBE_URL" ] && { [ -n "$PUBLIC_IPV4" ] || [ -n "$PUBLIC_IPV6" ]; }; then
    UNREACHABLE=$(get_unreachable_ips "$PROBE_URL" "$PUBLIC_IPV4" "$PUBLIC_IPV6")
    if [ -n "$UNREACHABLE" ]; then
        while IFS= read -r bad_ip; do
            [ -z "$bad_ip" ] && continue
            if [ "$bad_ip" = "$PUBLIC_IPV4" ]; then
                echo "→ IPv4 $PUBLIC_IPV4 not reachable from backend probe — dropping"
                PUBLIC_IPV4=""
            fi
            if [ "$bad_ip" = "$PUBLIC_IPV6" ]; then
                echo "→ IPv6 $PUBLIC_IPV6 not reachable from backend probe — dropping"
                PUBLIC_IPV6=""
            fi
        done <<< "$UNREACHABLE"
    fi
fi

# =============================================================================
# Persist verified addresses (or clear them when they didn't survive the probe)
# =============================================================================
PUBLIC_IPV6_DASH=""
if [ -n "$PUBLIC_IPV6" ]; then
    PUBLIC_IPV6_DASH=$(echo "$PUBLIC_IPV6" | tr ':' '-')
    set_env PUBLIC_IPV6 "$PUBLIC_IPV6"
    set_env PUBLIC_IPV6_DASH "$PUBLIC_IPV6_DASH"
    echo "✓ IPv6 configured: $PUBLIC_IPV6 (dash: $PUBLIC_IPV6_DASH)"
else
    set_env PUBLIC_IPV6 ""
    set_env PUBLIC_IPV6_DASH ""
    echo "→ No reachable public IPv6 address"
fi

PUBLIC_IPV4_DASH=""
if [ -n "$PUBLIC_IPV4" ]; then
    PUBLIC_IPV4_DASH=$(echo "$PUBLIC_IPV4" | tr '.' '-')
    set_env PUBLIC_IPV4 "$PUBLIC_IPV4"
    set_env PUBLIC_IPV4_DASH "$PUBLIC_IPV4_DASH"
    echo "✓ IPv4 configured: $PUBLIC_IPV4 (dash: $PUBLIC_IPV4_DASH)"
else
    set_env PUBLIC_IPV4 ""
    set_env PUBLIC_IPV4_DASH ""
    echo "→ No reachable public IPv4 address"
fi

# =============================================================================
# PUBLIC_IP — canonical (prefer IPv4 when both work, then IPv6, else localhost).
# Every consumer (mesh-router-agent, Caddy labels, settings-center-app) must
# read PUBLIC_IP/PUBLIC_IP_DASH only — never PUBLIC_IPV4/PUBLIC_IPV6 directly —
# so the registered route and the routing labels can never disagree.
# =============================================================================
if [ -n "$PUBLIC_IPV4" ]; then
    PUBLIC_IP="$PUBLIC_IPV4"
    PUBLIC_IP_DASH="$PUBLIC_IPV4_DASH"
elif [ -n "$PUBLIC_IPV6" ]; then
    PUBLIC_IP="$PUBLIC_IPV6"
    PUBLIC_IP_DASH="$PUBLIC_IPV6_DASH"
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
