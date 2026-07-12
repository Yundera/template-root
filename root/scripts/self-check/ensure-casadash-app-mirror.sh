#!/bin/bash
# ensure-casadash-app-mirror.sh - Project every CasaOS app into CasaDash's layout.
#
# For each app under /DATA/AppData/casaos/apps/<app> (CasaOS's AppsPath), write:
#     /DATA/AppData/<app>/docker-compose.yml   copy of CasaOS's compose file
#     /DATA/AppData/<app>/.env                 CasaOS's injected variables, materialised
#     /DATA/AppData/<app>/.casaos-mirror       provenance marker (this script's own)
#
# WHY: CasaDash already *sees* every CasaOS app without any of this — it reads the
# compose from the `com.docker.compose.project.working_dir` label over the Docker
# socket. What these files buy is the promotion from an "unmanaged" tile (open,
# start/stop/restart, logs, stats) to a "managed" one (+ Env / Compose / Override /
# WebUI / Tips editors and store Updates), because CasaDash's isManaged() is simply
# stat(/DATA/AppData/<app>/docker-compose.yml). They are also the artefact phase 2
# promotes into the real thing. See doc/casadash-migration.md.
#
# THIS SCRIPT NEVER RUNS `docker compose up`. It writes files only. CasaOS remains
# the sole writer of the source compose files and the sole installer.
#
# COPY, NOT HARDLINK. A hardlink between the two paths does not survive this tree:
#   - ensure-casaos-apps-up-to-date.sh rewrites stale nip.io/sslip.io labels with
#     `sed -i`, which REPLACES the inode — the link would split silently into two
#     divergent files on the first IP change;
#   - CasaDash's "Apply update" does os.WriteFile() on docker-compose.yml, which
#     truncates in place — through a shared inode that would rewrite CasaOS's copy
#     too, destroying its install-time $AUTH_HASH substitution and baked-in labels.
# Re-copying on every self-check gives the same convergence with none of that.
#
# ORDERING: must run AFTER ensure-casaos-apps-up-to-date.sh, so the copy reflects
# the post-`sed` compose files rather than the stale-label ones.
#
# THE .env IS THE VERIFICATION ARTEFACT. CasaOS uses no per-app .env at all: it
# interpolates each compose at up-time from the *casaos container's own* environment.
# We materialise exactly that variable set (the same cocktail
# ensure-casaos-apps-up-to-date.sh injects) so that the mirrored folder renders
# identically to CasaOS's — which this script then asserts with `docker compose
# config` on both sides, reporting MIRROR_DRIFT on any mismatch. A drifting mirror
# must not be trusted as a migration source.
set -euo pipefail

APPS_DIR="/DATA/AppData/casaos/apps"
DST_ROOT="/DATA/AppData"
YND_ROOT="$APPS_DIR/yundera"
YUNDERA_ENV="$YND_ROOT/.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
MARKER_NAME=".casaos-mirror"

source "$YND_ROOT/scripts/library/log.sh"

if [ ! -d "$APPS_DIR" ]; then
    echo "Apps directory does not exist, skipping"
    exit 0
fi
if [ ! -f "$YUNDERA_ENV" ]; then
    echo "Yundera .env not found, skipping"
    exit 0
fi

# Same source variables, read the same way, as ensure-casaos-apps-up-to-date.sh —
# these two scripts must agree exactly or the render comparison below is meaningless.
DEFAULT_PWD=$("$ENV_MGR" get DEFAULT_PWD "$YUNDERA_ENV")
DOMAIN=$("$ENV_MGR" get DOMAIN "$YUNDERA_ENV")
PUBLIC_IPV4=$("$ENV_MGR" get PUBLIC_IPV4 "$YUNDERA_ENV")
PUBLIC_IPV6=$("$ENV_MGR" get PUBLIC_IPV6 "$YUNDERA_ENV")
# Canonical dash form — never PUBLIC_IPV4_DASH / PUBLIC_IPV6_DASH directly.
# See the invariant at the bottom of ensure-public-ip.sh.
PUBLIC_IP_DASH=$("$ENV_MGR" get PUBLIC_IP_DASH "$YUNDERA_ENV")
PUBLIC_IPV4_DASH=$("$ENV_MGR" get PUBLIC_IPV4_DASH "$YUNDERA_ENV")
PUBLIC_IPV6_DASH=$("$ENV_MGR" get PUBLIC_IPV6_DASH "$YUNDERA_ENV")
EMAIL=$("$ENV_MGR" get EMAIL "$YUNDERA_ENV")
[ -z "$EMAIL" ] && EMAIL="admin@$DOMAIN"

if [ -f /etc/timezone ]; then
    TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
elif [ -L /etc/localtime ]; then
    TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
else
    TZ="UTC"
fi

mirrored_count=0
skipped_count=0
conflict_count=0
unverified_count=0
drifted_apps=()

# Render a compose file the way CasaOS does: variables supplied through the process
# environment, exactly as the casaos container supplies them at `up` time.
#
# HERMETIC (`env -i`), like render_from_dotenv below. Both sides must see exactly the
# variables we name and nothing else, or the comparison depends on WHO ran the
# self-check: an interactive `sudo` shell carries a rich environment, the 3am cron
# carries almost none. An app compose referencing any ambient variable would then
# render differently between the two, and drift would appear or vanish depending on
# the invoker rather than on the mirror actually being wrong.
render_as_casaos() {
    local compose_file="$1" app_name="$2" dir="$3"
    env -i PATH="$PATH" HOME="${HOME:-/root}" \
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
    APP_PUBLIC_IP_DASH="$PUBLIC_IP_DASH" \
    APP_PUBLIC_IPV4="$PUBLIC_IPV4" \
    APP_PUBLIC_IPV4_DASH="$PUBLIC_IPV4_DASH" \
    APP_PUBLIC_IPV6="$PUBLIC_IPV6" \
    APP_PUBLIC_IPV6_DASH="$PUBLIC_IPV6_DASH" \
    APP_EMAIL="$EMAIL" \
    APP_NET="pcs" \
    COMPOSE_PROJECT_NAME="$app_name" \
    docker compose --project-directory "$dir" -f "$compose_file" config 2>/dev/null
}

# Render the mirrored folder the way CasaDash will: nothing in the process
# environment, everything from the generated .env. `env -i` is what makes this a
# real test — inheriting our own exports would prove nothing about the .env.
render_from_dotenv() {
    local dir="$1"
    env -i PATH="$PATH" HOME="${HOME:-/root}" \
        docker compose --project-directory "$dir" -f "$dir/docker-compose.yml" config 2>/dev/null
}

for app_dir in "$APPS_DIR"/*/; do
    [ -d "$app_dir" ] || continue

    app_name=$(basename "$app_dir")
    src_compose="$app_dir/docker-compose.yml"

    # The yundera stack is the template itself, not a user app.
    [ "$app_name" = "yundera" ] && continue
    [ -f "$src_compose" ] || continue

    # CasaDash ignores any directory whose name contains a dot (that is how its own
    # .casadash state dir and <app>.<date>.archive folders stay off the grid), so a
    # mirror of such an app could never be seen. Don't create a misleading folder.
    if [[ "$app_name" == *.* ]]; then
        log_warn "Skipping '$app_name': CasaDash ignores directory names containing a dot"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    dst_dir="$DST_ROOT/$app_name"
    dst_compose="$dst_dir/docker-compose.yml"
    marker="$dst_dir/$MARKER_NAME"

    # $dst_dir almost always exists already — it is the app's DATA directory
    # (/DATA/AppData/<app>), and CasaDash's flat layout deliberately puts the compose
    # file next to the data. That is fine. What we must never do is clobber a compose
    # file we did not write: a compose present WITHOUT our marker means a
    # CasaDash-native app (phase 2) owns this folder.
    if [ -f "$dst_compose" ] && [ ! -f "$marker" ]; then
        log_warn "Skipping '$app_name': $dst_compose exists but is not a mirror (CasaDash-native app?)"
        conflict_count=$((conflict_count + 1))
        continue
    fi

    mkdir -p "$dst_dir"

    # Preserve any pre-existing .env exactly once, before we first take the folder over.
    if [ ! -f "$marker" ] && [ -f "$dst_dir/.env" ]; then
        cp -p "$dst_dir/.env" "$dst_dir/.env.pre-casadash.bak"
        log_warn "Backed up pre-existing $dst_dir/.env to .env.pre-casadash.bak"
    fi

    # --- compose file (only write on change, to keep mtimes stable) ---
    if ! cmp -s "$src_compose" "$dst_compose"; then
        cp "$src_compose" "$dst_compose"
        chmod 644 "$dst_compose"
    fi

    # --- .env: CasaOS's injected variables, materialised ---
    tmp_env="$(mktemp)"
    chmod 600 "$tmp_env"
    {
        echo "# AUTO-GENERATED FILE - DO NOT EDIT"
        echo "# Mirror of the environment CasaOS injects into '$app_name' at compose-up"
        echo "# time. Written by scripts/self-check/ensure-casadash-app-mirror.sh and"
        echo "# regenerated on every self-check. CasaOS itself does not read this file."
        echo ""

        # An app may ship its OWN .env in its CasaOS app directory, holding secrets
        # generated at install time (e.g. `hubs` keeps its Postgres password, Phoenix
        # / Guardian keys and an RSA private key there). Compose auto-loads that file
        # from the project directory, so CasaOS resolves those variables — and a
        # mirror without them renders the app with empty passwords. Merge it in.
        #
        # It goes FIRST, before the injected cocktail below, because duplicate keys in
        # a .env resolve last-wins: that reproduces CasaOS's precedence, where the
        # process environment (the cocktail) overrides the project .env.
        if [ -f "$app_dir/.env" ]; then
            echo "# --- from $app_dir.env (app-owned, generated at install) ---"
            cat "$app_dir/.env"
            echo ""
        fi

        echo "# --- injected by CasaOS at compose-up (overrides the above) ---"
        # Pins the project identity independently of the directory name, so this
        # folder always acts on the SAME docker project as CasaOS's copy.
        echo "COMPOSE_PROJECT_NAME=$app_name"
        echo "AppID=$app_name"
        echo "PUID=1000"
        echo "PGID=1000"
        echo "TZ=$TZ"
        echo ""
        echo "# (deprecated) V1"
        echo "default_pwd=$DEFAULT_PWD"
        echo "public_ip=$PUBLIC_IPV4"
        echo "domain=$DOMAIN"
        echo ""
        echo "# (deprecated) V2"
        echo "PCS_DEFAULT_PASSWORD=$DEFAULT_PWD"
        echo "PCS_DOMAIN=$DOMAIN"
        echo "PCS_DATA_ROOT=/DATA"
        echo "PCS_PUBLIC_IP=$PUBLIC_IPV4"
        echo "PCS_PUBLIC_IPV6=$PUBLIC_IPV6"
        echo "PCS_EMAIL=$EMAIL"
        echo ""
        echo "# V3"
        echo "APP_DEFAULT_PASSWORD=$DEFAULT_PWD"
        echo "APP_DOMAIN=$DOMAIN"
        echo "APP_DATA_ROOT=/DATA"
        echo "APP_PUBLIC_IP=$PUBLIC_IPV6"
        echo "APP_PUBLIC_IP_DASH=$PUBLIC_IP_DASH"
        echo "APP_PUBLIC_IPV4=$PUBLIC_IPV4"
        echo "APP_PUBLIC_IPV4_DASH=$PUBLIC_IPV4_DASH"
        echo "APP_PUBLIC_IPV6=$PUBLIC_IPV6"
        echo "APP_PUBLIC_IPV6_DASH=$PUBLIC_IPV6_DASH"
        echo "APP_EMAIL=$EMAIL"
        echo "APP_NET=pcs"
    } > "$tmp_env"

    if ! cmp -s "$tmp_env" "$dst_dir/.env"; then
        mv "$tmp_env" "$dst_dir/.env"
        chmod 600 "$dst_dir/.env"
    else
        rm -f "$tmp_env"
    fi

    echo "mirrored by ensure-casadash-app-mirror.sh" > "$marker"

    # /DATA is owned by pcs:pcs (uid/gid 1000); keep the mirrored files consistent
    # so the casadash container (PUID/PGID 1000) can read them.
    chown 1000:1000 "$dst_compose" "$dst_dir/.env" "$marker" 2>/dev/null || true

    # --- verification: both sides must render identically ---
    # Capture rather than diff <(…) directly: a compose file that fails to render
    # produces EMPTY output, and two empty renders compare equal — a vacuous pass.
    # Some apps genuinely don't render (they reference variables nobody injects,
    # e.g. an app expecting ENV_FILE); that is pre-existing CasaOS behaviour and not
    # something this mirror introduces, so it is reported as unverifiable rather
    # than as drift. But an empty mirror render against a good CasaOS render is a
    # real failure and must be caught.
    casaos_render="$(render_as_casaos "$src_compose" "$app_name" "$app_dir" || true)"
    mirror_render="$(render_from_dotenv "$dst_dir" || true)"

    if [ -z "$casaos_render" ] && [ -z "$mirror_render" ]; then
        log_warn "Cannot verify '$app_name': neither CasaOS nor the mirror renders this compose"
        unverified_count=$((unverified_count + 1))
    elif [ "$casaos_render" != "$mirror_render" ]; then
        drifted_apps+=("$app_name")
    fi

    mirrored_count=$((mirrored_count + 1))
done

echo "CasaDash mirror: $mirrored_count mirrored, $skipped_count skipped, $conflict_count conflicts, $unverified_count unverifiable, ${#drifted_apps[@]} drifted"

if [ "${#drifted_apps[@]}" -gt 0 ]; then
    # The mirrored folder does NOT render the same compose as CasaOS does. Managing
    # this app from CasaDash would produce a different container spec than CasaOS
    # would — it is not safe to promote in phase 2. Surface it and fail the check.
    for app in "${drifted_apps[@]}"; do
        echo "MIRROR_DRIFT: $app: mirrored render differs from CasaOS render"
    done
    exit 1
fi

exit 0
