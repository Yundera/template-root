#!/bin/bash
set -e

# Ensure CasaOS apps are up-to-date
# For each app with at least one running container, run docker compose up -d
# with remixed environment variables matching CasaOS injection pattern.
#
# FORCE_START=1 bypasses the "only if at least one container is running" gate.
# Used by the migration pipeline's start_user_apps step (Migration.ts), where
# the apps were just rsynced onto a fresh target and so are necessarily not
# running yet — the normal gate would skip them all and leave the user with
# data but no running services. Outside that one-shot post-migration call,
# the gate must stay: it's the protection against bringing back up apps the
# user has intentionally stopped from the CasaOS UI.

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
PUBLIC_IPV4_DASH=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get PUBLIC_IPV4_DASH "$YUNDERA_ENV")
[ -z "$PUBLIC_IPV4_DASH" ] && PUBLIC_IPV4_DASH="${PUBLIC_IPV4//./-}"
PUBLIC_IPV6=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get PUBLIC_IPV6 "$YUNDERA_ENV")
EMAIL=$("$YND_ROOT/scripts/tools/env-file-manager.sh" get EMAIL "$YUNDERA_ENV")
# Apps expect a routable address for password resets, alerts, etc. Fall back to
# admin@$DOMAIN only if the operator email wasn't provisioned into the env.
[ -z "$EMAIL" ] && EMAIL="admin@$DOMAIN"

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

    # Rewrite stale IP-encoded subdomain labels to the current PCS IP.
    #
    # CasaOS bakes the resolved value of `${PUBLIC_IPV4_DASH}` into caddy
    # labels at app-install time (instead of leaving the placeholder in the
    # saved compose file), so any later IP change — a migration to a new
    # provider, an IP reassignment by the host — leaves
    # `caddy_N: app-<old-ip-dash>.nip.io` / `.sslip.io` labels pointing at
    # the previous IP. caddy-docker-proxy then registers a route for a vhost
    # nobody is hitting, and the actual IP-based subdomain falls through to
    # the catch-all (CasaOS). This is a CasaOS-side bug; rewriting here is
    # the short-term mitigation until install-time stops resolving the
    # placeholders. Match shape `\d+-\d+-\d+-\d+\.(nip|sslip)\.io` so we
    # only touch the IP-encoded subdomains, never the `${user}.${domain}`
    # ones. Skipped when every IP-DASH in the file already matches the
    # current PUBLIC_IPV4_DASH (idempotent re-runs don't dirty the file).
    if [ -n "$PUBLIC_IPV4_DASH" ] && \
       grep -qE "[0-9]+-[0-9]+-[0-9]+-[0-9]+\.(nip|sslip)\.io" "$compose_file"; then
        stale=$(grep -oE "[0-9]+-[0-9]+-[0-9]+-[0-9]+\.(nip|sslip)\.io" "$compose_file" \
            | awk -F. '{print $1}' \
            | sort -u \
            | grep -v "^${PUBLIC_IPV4_DASH}\$" \
            | head -1)
        if [ -n "$stale" ]; then
            echo "Rewriting stale IP-DASH labels in $app_name ($stale → $PUBLIC_IPV4_DASH)"
            # Use `#` as the sed delimiter — `|` would be consumed by the
            # `(nip|sslip)` alternation in the regex and sed would parse
            # things wrong.
            sed -i -E "s#[0-9]+-[0-9]+-[0-9]+-[0-9]+\.(nip|sslip)\.io#${PUBLIC_IPV4_DASH}.\1.io#g" \
                "$compose_file"
        fi
    fi

    # Check if at least one container is running — unless FORCE_START=1
    # tells us the caller knows the apps need to come up fresh (post-migration).
    if [ "${FORCE_START:-0}" != "1" ]; then
        running_containers=$(docker compose -f "$compose_file" ps -q 2>/dev/null | wc -l)
        if [ "$running_containers" -eq 0 ]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
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
    PCS_EMAIL="$EMAIL" \
    APP_DEFAULT_PASSWORD="$DEFAULT_PWD" \
    APP_DOMAIN="$DOMAIN" \
    APP_DATA_ROOT="/DATA" \
    APP_PUBLIC_IP="$PUBLIC_IPV6" \
    APP_PUBLIC_IPV4="$PUBLIC_IPV4" \
    APP_PUBLIC_IPV6="$PUBLIC_IPV6" \
    APP_EMAIL="$EMAIL" \
    APP_NET="pcs" \
    docker compose -f "$compose_file" up --quiet-pull -d

    updated_count=$((updated_count + 1))
done

if [ "$updated_count" -gt 0 ] || [ "$skipped_count" -gt 0 ]; then
    echo "Apps: $updated_count updated, $skipped_count skipped (not running)"
fi

exit 0
