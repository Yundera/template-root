#!/bin/bash
set -e

# Ensure CasaOS apps are up-to-date
# For each app with at least one running container, run docker compose up -d
# with remixed environment variables matching CasaOS injection pattern

APPS_DIR="/DATA/AppData/casaos/apps"
YND_ROOT="$APPS_DIR/yundera"
YUNDERA_ENV="$YND_ROOT/.env"

# Skip if apps directory doesn't exist
if [ ! -d "$APPS_DIR" ]; then
    echo "Apps directory does not exist, skipping"
    exit 0
fi

# Skip if yundera .env doesn't exist
if [ ! -f "$YUNDERA_ENV" ]; then
    echo "Yundera .env not found, skipping"
    exit 0
fi

# Read source variables using unified env file manager
DEFAULT_PWD=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get DEFAULT_PWD "$YUNDERA_ENV")
DOMAIN=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get DOMAIN "$YUNDERA_ENV")
PUBLIC_IPV4=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get PUBLIC_IPV4 "$YUNDERA_ENV")
PUBLIC_IPV6=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get PUBLIC_IPV6 "$YUNDERA_ENV")

# Detect timezone
if [ -f /etc/timezone ]; then
    TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
elif [ -L /etc/localtime ]; then
    TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
else
    TZ="UTC"
fi

# Track stats
updated_count=0
skipped_count=0

for app_dir in "$APPS_DIR"/*/; do
    [ -d "$app_dir" ] || continue

    app_name=$(basename "$app_dir")
    compose_file="$app_dir/docker-compose.yml"

    # Skip yundera (has its own ensure script)
    if [ "$app_name" = "yundera" ]; then
        continue
    fi

    # Skip if no docker-compose.yml
    if [ ! -f "$compose_file" ]; then
        continue
    fi

    # Check if at least one container is running
    running_containers=$(docker compose -f "$compose_file" ps -q 2>/dev/null | wc -l)
    if [ "$running_containers" -eq 0 ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi

    echo "Updating app: $app_name"

    # Run docker compose up -d with remixed environment variables
    # Variables are exported inline to avoid temp files
    AppID="$app_name" \
    PUID=1000 \
    PGID=1000 \
    TZ="$TZ" \
    default_pwd="$DEFAULT_PWD" \
    public_ip="$PUBLIC_IPV4" \
    domain="$DOMAIN" \
    PCS_DEFAULT_PASSWORD="$DEFAULT_PWD" \
    PCS_DOMAIN="$DOMAIN" \
    PCS_DATA_ROOT="/DATA" \
    PCS_PUBLIC_IP="$PUBLIC_IPV4" \
    PCS_PUBLIC_IPV6="$PUBLIC_IPV6" \
    PCS_EMAIL="admin@$DOMAIN" \
    APP_DEFAULT_PASSWORD="$DEFAULT_PWD" \
    APP_DOMAIN="$DOMAIN" \
    APP_DATA_ROOT="/DATA" \
    APP_PUBLIC_IP="$PUBLIC_IPV6" \
    APP_PUBLIC_IPV4="$PUBLIC_IPV4" \
    APP_PUBLIC_IPV6="$PUBLIC_IPV6" \
    APP_EMAIL="admin@$DOMAIN" \
    APP_NET="pcs" \
    docker compose -f "$compose_file" up --quiet-pull -d

    updated_count=$((updated_count + 1))
done

if [ "$updated_count" -gt 0 ] || [ "$skipped_count" -gt 0 ]; then
    echo "Apps: $updated_count updated, $skipped_count skipped (not running)"
fi

exit 0
