#!/bin/bash
set -euo pipefail

# Migration: Ensure Caddy labels exist for all CasaOS apps
# Type: Always-run migration (runs on every template sync)
# Purpose: Add Caddy reverse proxy labels to apps that don't have them
#
# This migration adds Caddy labels to CasaOS apps for automatic reverse proxy
# configuration. It only modifies apps that:
# - Have a docker-compose.yml file
# - Are NOT the yundera core stack (store_app_id != yundera, category != pcs)
# - Don't already have caddy labels on the main service
#
# Labels added (certificate strategy):
#   caddy_0: {hostname} - gateway-routed domain with custom CA
#   caddy_0.import: gateway_tls
#   caddy_0.reverse_proxy: "{{upstreams {webui_port}}}"
#
#   caddy_1: {app}-{PUBLIC_IP_DASH}.nip.io - direct access with custom CA
#   caddy_1.import: gateway_tls
#   caddy_1.reverse_proxy: "{{upstreams {webui_port}}}"
#
#   caddy_2: {app}-{PUBLIC_IP_DASH}.sslip.io - direct access with Let's Encrypt
#   caddy_2.reverse_proxy: "{{upstreams {webui_port}}}"

APPS_DIR="/DATA/AppData/casaos/apps"
YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"

# Skip if apps directory doesn't exist
if [ ! -d "$APPS_DIR" ]; then
    echo "Apps directory does not exist, skipping"
    exit 0
fi

# Check if yq is installed
if ! command -v yq &>/dev/null; then
    echo "yq is not installed, skipping Caddy labels migration"
    exit 0
fi

# Read PUBLIC_IP_DASH from environment
PUBLIC_IP_DASH=""
if [ -f "$PCS_ENV_FILE" ]; then
    PUBLIC_IP_DASH=$(grep "^PUBLIC_IP_DASH=" "$PCS_ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
fi

if [ -z "$PUBLIC_IP_DASH" ]; then
    echo "Warning: PUBLIC_IP_DASH not set, skipping nip.io/sslip.io labels"
fi

# Track stats
added_count=0
upgraded_count=0
skipped_count=0
error_count=0

for app_dir in "$APPS_DIR"/*/; do
    # Skip if not a directory
    [ -d "$app_dir" ] || continue

    app_name=$(basename "$app_dir")
    compose_file="$app_dir/docker-compose.yml"

    # Skip non-compose apps
    if [ ! -f "$compose_file" ]; then
        continue
    fi

    # Read x-casaos metadata
    store_app_id=$(yq -r '.x-casaos.store_app_id // ""' "$compose_file" 2>/dev/null || echo "")
    category=$(yq -r '.x-casaos.category // ""' "$compose_file" 2>/dev/null || echo "")
    main_service=$(yq -r '.x-casaos.main // ""' "$compose_file" 2>/dev/null || echo "")
    webui_port=$(yq -r '.x-casaos.port_map // ""' "$compose_file" 2>/dev/null || echo "")
    hostname=$(yq -r '.x-casaos.hostname // ""' "$compose_file" 2>/dev/null || echo "")

    # Skip yundera core stack
    if [ "$store_app_id" = "yundera" ] || [ "$category" = "pcs" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # Skip if missing required fields
    if [ -z "$main_service" ]; then
        echo "Warning: $app_name has no main service defined, skipping"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    if [ -z "$webui_port" ]; then
        echo "Warning: $app_name has no port_map defined, skipping"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    if [ -z "$hostname" ]; then
        echo "Warning: $app_name has no hostname defined, skipping"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # Check if main service exists
    service_exists=$(yq -r ".services.\"$main_service\" // \"\"" "$compose_file" 2>/dev/null || echo "")
    if [ -z "$service_exists" ] || [ "$service_exists" = "null" ]; then
        echo "Warning: $app_name main service '$main_service' not found, skipping"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # Check if new format labels already exist (caddy_0 with caddy_1 and caddy_2)
    existing_caddy_0=$(yq -r ".services.\"$main_service\".labels.caddy_0 // \"\"" "$compose_file" 2>/dev/null || echo "")
    existing_caddy_1=$(yq -r ".services.\"$main_service\".labels.caddy_1 // \"\"" "$compose_file" 2>/dev/null || echo "")
    existing_caddy_2=$(yq -r ".services.\"$main_service\".labels.caddy_2 // \"\"" "$compose_file" 2>/dev/null || echo "")

    # Skip if already has full new format (caddy_0 + caddy_1 + caddy_2)
    if [ -n "$existing_caddy_0" ] && [ "$existing_caddy_0" != "null" ] && \
       [ -n "$existing_caddy_1" ] && [ "$existing_caddy_1" != "null" ] && \
       [ -n "$existing_caddy_2" ] && [ "$existing_caddy_2" != "null" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # Check for old-style single caddy label that needs migration
    old_caddy=$(yq -r ".services.\"$main_service\".labels.caddy // \"\"" "$compose_file" 2>/dev/null || echo "")
    has_old_format=false
    if [ -n "$old_caddy" ] && [ "$old_caddy" != "null" ]; then
        has_old_format=true
    fi

    if $has_old_format; then
        echo "Upgrading Caddy labels for: $app_name (service: $main_service, port: $webui_port)"
    else
        echo "Adding Caddy labels to: $app_name (service: $main_service, port: $webui_port)"
    fi

    # Create backup
    cp "$compose_file" "$compose_file.backup"

    # Remove old-style caddy labels if present
    if $has_old_format; then
        yq -i "del(.services.\"$main_service\".labels.caddy)" "$compose_file" 2>/dev/null || true
        yq -i "del(.services.\"$main_service\".labels.\"caddy.reverse_proxy\")" "$compose_file" 2>/dev/null || true
        yq -i "del(.services.\"$main_service\".labels.\"caddy.import\")" "$compose_file" 2>/dev/null || true
    fi

    # Add Caddy labels using yq
    # First ensure labels is a map (not array)
    if ! yq -e ".services.\"$main_service\".labels" "$compose_file" >/dev/null 2>&1; then
        # No labels section exists, create it
        yq -i ".services.\"$main_service\".labels = {}" "$compose_file"
    fi

    # Check if labels is an array and convert to map if needed
    labels_type=$(yq -r ".services.\"$main_service\".labels | type" "$compose_file" 2>/dev/null || echo "")
    if [ "$labels_type" = "!!seq" ]; then
        # Convert array labels to map format
        # First, read existing array labels into temp
        existing_labels=$(yq -r ".services.\"$main_service\".labels[]" "$compose_file" 2>/dev/null || echo "")

        # Clear and recreate as map
        yq -i ".services.\"$main_service\".labels = {}" "$compose_file"

        # Re-add existing labels as key-value pairs
        while IFS= read -r label; do
            if [ -n "$label" ]; then
                key="${label%%=*}"
                value="${label#*=}"
                yq -i ".services.\"$main_service\".labels.\"$key\" = \"$value\"" "$compose_file"
            fi
        done <<< "$existing_labels"
    fi

    # Extract app prefix from hostname for nip.io/sslip.io domains
    # hostname format: {app}-{DOMAIN} -> extract {app} part
    app_prefix=$(echo "$hostname" | sed 's/-[^-]*\.[^.]*\.[^.]*$//' || echo "$app_name")

    # Add caddy labels with certificate strategy
    update_success=true

    # caddy_0: Gateway-routed domain with custom CA
    yq -i ".services.\"$main_service\".labels.caddy_0 = \"$hostname\"" "$compose_file" || update_success=false
    yq -i ".services.\"$main_service\".labels.\"caddy_0.import\" = \"gateway_tls\"" "$compose_file" || update_success=false
    yq -i ".services.\"$main_service\".labels.\"caddy_0.reverse_proxy\" = \"{{upstreams $webui_port}}\"" "$compose_file" || update_success=false

    # caddy_1 and caddy_2: nip.io and sslip.io domains (if PUBLIC_IP_DASH is available)
    if [ -n "$PUBLIC_IP_DASH" ]; then
        # caddy_1: nip.io with custom CA
        yq -i ".services.\"$main_service\".labels.caddy_1 = \"${app_prefix}-${PUBLIC_IP_DASH}.nip.io\"" "$compose_file" || update_success=false
        yq -i ".services.\"$main_service\".labels.\"caddy_1.import\" = \"gateway_tls\"" "$compose_file" || update_success=false
        yq -i ".services.\"$main_service\".labels.\"caddy_1.reverse_proxy\" = \"{{upstreams $webui_port}}\"" "$compose_file" || update_success=false

        # caddy_2: sslip.io with Let's Encrypt (no import directive)
        yq -i ".services.\"$main_service\".labels.caddy_2 = \"${app_prefix}-${PUBLIC_IP_DASH}.sslip.io\"" "$compose_file" || update_success=false
        yq -i ".services.\"$main_service\".labels.\"caddy_2.reverse_proxy\" = \"{{upstreams $webui_port}}\"" "$compose_file" || update_success=false
    fi

    if $update_success; then
        rm -f "$compose_file.backup"
        if $has_old_format; then
            upgraded_count=$((upgraded_count + 1))
        else
            added_count=$((added_count + 1))
        fi
    else
        echo "Error: Failed to update $app_name, restoring backup"
        mv "$compose_file.backup" "$compose_file"
        error_count=$((error_count + 1))
    fi
done

if [ "$added_count" -gt 0 ] || [ "$upgraded_count" -gt 0 ] || [ "$skipped_count" -gt 0 ] || [ "$error_count" -gt 0 ]; then
    echo "Caddy labels: $added_count added, $upgraded_count upgraded, $skipped_count skipped, $error_count errors"
fi

exit 0
