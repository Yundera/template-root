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
# Labels added:
#   caddy: {hostname from x-casaos}
#   caddy.reverse_proxy: "{{upstreams {webui_port}}}"

APPS_DIR="/DATA/AppData/casaos/apps"

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

# Track stats
updated_count=0
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
    webui_port=$(yq -r '.x-casaos.webui_port // ""' "$compose_file" 2>/dev/null || echo "")
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
        echo "Warning: $app_name has no webui_port defined, skipping"
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

    # Check if caddy label already exists on main service
    existing_caddy=$(yq -r ".services.\"$main_service\".labels.caddy // \"\"" "$compose_file" 2>/dev/null || echo "")

    # Also check array-style labels
    if [ -z "$existing_caddy" ] || [ "$existing_caddy" = "null" ]; then
        existing_caddy=$(yq -r ".services.\"$main_service\".labels[] | select(startswith(\"caddy=\")) // \"\"" "$compose_file" 2>/dev/null || echo "")
    fi

    if [ -n "$existing_caddy" ] && [ "$existing_caddy" != "null" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi

    echo "Adding Caddy labels to: $app_name (service: $main_service, port: $webui_port)"

    # Create backup
    cp "$compose_file" "$compose_file.backup"

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

    # Add caddy labels
    if yq -i ".services.\"$main_service\".labels.caddy = \"$hostname\"" "$compose_file" && \
       yq -i ".services.\"$main_service\".labels.\"caddy.reverse_proxy\" = \"{{upstreams $webui_port}}\"" "$compose_file"; then
        rm -f "$compose_file.backup"
        updated_count=$((updated_count + 1))
    else
        echo "Error: Failed to update $app_name, restoring backup"
        mv "$compose_file.backup" "$compose_file"
        error_count=$((error_count + 1))
    fi
done

if [ "$updated_count" -gt 0 ] || [ "$skipped_count" -gt 0 ] || [ "$error_count" -gt 0 ]; then
    echo "Caddy labels: $updated_count updated, $skipped_count skipped, $error_count errors"
fi

exit 0
