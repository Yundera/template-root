#!/bin/bash
# mesh.sh - the contract between this template and the stock mesh template.
#
# A PCS runs Yundera/mesh-router-template-root UNMODIFIED in /DATA/AppData/mesh
# (mesh, auth, maison and terminal stacks, its own self-check, cron, lock, log and
# update channel). This template never edits a file the mesh template wrote. It
# only writes INPUTS the mesh template reads — keys in its .env, drop-in files —
# and runs the mesh scripts that consume them. See doc/mesh-stock-switch.md.
#
# Everything this template knows about the mesh template is in this file: where
# it lives, which channel a PCS follows, which .env keys go which way, and how to
# run one of its scripts without racing its own cron.
#
# Expects log.sh to be sourced already.

YND_ROOT="${YND_ROOT:-/DATA/AppData/yundera}"
YND_TEMPLATE="${YND_TEMPLATE:-$YND_ROOT/template}"

MESH_ROOT="/DATA/AppData/mesh"
MESH_ENV="$MESH_ROOT/.env"
MESH_SCRIPTS="$MESH_ROOT/scripts"
# The mesh self-check's own flock (its scripts/self-check.sh). Disjoint from
# /var/run/yundera-self-check.lock: the two templates run independently.
MESH_LOCK="/var/run/mesh-self-check.lock"
MESH_REPO_URL="https://github.com/yundera/mesh-router-template-root"
MESH_CDN_BASE="https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root"

MESH_ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"

# --- the .env contract ---------------------------------------------------------
#
# EVERY RUN: Yundera is the source of truth. Taken from this template's own env
# files and upserted on every self-check. PROVIDER_STR and DOMAIN are NOT in this
# list even though Yundera owns them: they are the box's identity, and an identity
# change goes through the mesh install.sh (--provider/--domain), which is what
# takes the mesh stack down to apply it cleanly. Upserting them here first would
# hide the change from the installer. See ensure-mesh-installed.sh.
MESH_KEYS_EVERY_RUN="EMAIL DEFAULT_PWD TERMINAL_ENABLED SMTP_TO APPSTORE_URL OPERATOR_API"

# Constants: what a PCS is, in the mesh template's own knobs (its README,
# "Configuration (.env keys)"). EMAIL_SYNC=false because on a PCS the
# orchestrator's EMAIL is authoritative and upserted above; the mesh template's
# backend lookup would otherwise write its own value back on every run.
#
# The two MIGRATE_* keys plug this template into the mesh migrate.sh (its README,
# "Moving the box to another machine"): run this template's self-check on the
# target after the mesh one (users, SSH, backups, user stacks), and hold this
# template's lock on the source for the whole run so its nightly self-check does
# not restart the apps the migration stopped.
mesh_constants() {
    cat <<EOF
DATA_ROOT=/DATA
PUID=1000
PGID=1000
PUBLIC_IP_MODE=interface
TERMINAL_USER=admin
BRAND_NAME=Yundera
DEX_THEME_SRC=$YND_TEMPLATE/dex-theme
PLATFORM_PROJECTS=mesh,auth,yundera,maison,kopia,terminal
TRUSTED_PUBKEY_HOST_SUFFIXES=yundera.com
BACKUP_ENGINE_CONTAINER=kopia-engine
EMAIL_SYNC=false
MIGRATE_TARGET_SELF_CHECK=$YND_TEMPLATE/scripts/self-check.sh
MIGRATE_HOLD_LOCKS=/var/run/yundera-self-check.lock
EOF
}

# SEED ONCE: written only when absent from the mesh .env, then the mesh stack's
# own. Either the owner may change them from Mesh Console (the update channel,
# the schedule, the default app) or the mesh template writes them itself (the
# claimed owner name, the secrets it would otherwise mint). A nightly upsert
# would put back what they changed. The secrets are seeded from .pcs.secret.env
# when this template minted them before the switch, which is what keeps them
# STABLE across it: a second DEFAULT_PWD breaks every installed app.
#
# NOT AUTHELIA_DEX_SECRET, DEX_SESSION_KEY or AUTH_CONSOLE_ASSERTION_SECRET any more.
# The mesh template moved them out of its .env into the auth stack's own
# /DATA/AppData/auth/.stack.env, deleting them from the .env as it goes. Seeding them
# here would put them back every night for the mesh to delete again. Every box is
# past the switch, so the seed has done its job; a fresh box never had them.
MESH_KEYS_SEED_ONCE="DEFAULT_SERVICE_HOST DEFAULT_SERVICE_PORT LOCAL_ADMIN_USER
    MESH_CONSOLE_ASSERTION_SECRET"

# READ BACK: the mesh template owns them; ensure-env-vars-valid.sh takes them
# from the mesh .env into the unified .env, over any stale .pcs.env copy.
MESH_KEYS_READ_BACK="PUBLIC_IP PUBLIC_IP_DASH PUBLIC_IPV4 PUBLIC_IPV4_DASH PUBLIC_IPV6 PUBLIC_IPV6_DASH
    DEFAULT_SERVICE_HOST DEFAULT_SERVICE_PORT LOCAL_ADMIN_USER"

# The nightly schedule seeded for the mesh cron: after this template's own 03:00
# run, so a value this template upserts at 03:00 is applied by the mesh at 03:30.
MESH_SELF_CHECK_CRON_DEFAULT="30 3 * * *"

# --- reading ---------------------------------------------------------------------

# A key from this template's own sources, in the precedence the unified .env
# gives them (.ynd.user.env over .pcs.secret.env over .pcs.env). Prints nothing
# and returns 1 when no source has the key.
ynd_source_get() {
    local key="$1" f
    for f in "$YND_ROOT/.ynd.user.env" "$YND_ROOT/.pcs.secret.env" "$YND_ROOT/.pcs.env"; do
        if "$MESH_ENV_MGR" exists "$key" "$f" 2>/dev/null; then
            "$MESH_ENV_MGR" get "$key" "$f"
            return 0
        fi
    done
    return 1
}

mesh_env_get() {
    "$MESH_ENV_MGR" get "$1" "$MESH_ENV" 2>/dev/null || true
}

mesh_env_has() {
    "$MESH_ENV_MGR" exists "$1" "$MESH_ENV" 2>/dev/null
}

mesh_installed() {
    [ -f "$MESH_SCRIPTS/self-check.sh" ]
}

# --- channel -------------------------------------------------------------------

# The mesh branch a PCS follows, from this template's own channel: a box on
# template-root `main` (staging) follows mesh `main`, everything else `stable`.
# The mesh template updates itself from that channel from then on — this only
# decides the value seeded at install.
mesh_channel_branch() {
    case "$(ynd_source_get UPDATE_URL 2>/dev/null || true)" in
        */template-root/archive/refs/heads/main.zip) echo main ;;
        *) echo stable ;;
    esac
}

# The tarball the mesh installs from. MESH_UPDATE_URL in .pcs.env overrides it —
# a test tree served as file:// (see the mesh template's README), or a fork.
mesh_channel_url() {
    local override
    override="$("$MESH_ENV_MGR" get MESH_UPDATE_URL "$YND_ROOT/.pcs.env" 2>/dev/null || true)"
    if [ -n "$override" ]; then
        echo "$override"
    else
        echo "$MESH_REPO_URL/archive/refs/heads/$(mesh_channel_branch).tar.gz"
    fi
}

# The installer, from jsDelivr at the same branch. MESH_INSTALLER_URL in .pcs.env
# overrides it, for the same reasons. jsDelivr caches it for 12h: a mesh release
# that changes install.sh needs the purge its README describes.
mesh_installer_url() {
    local override branch
    override="$("$MESH_ENV_MGR" get MESH_INSTALLER_URL "$YND_ROOT/.pcs.env" 2>/dev/null || true)"
    if [ -n "$override" ]; then
        echo "$override"
        return 0
    fi
    branch="$(mesh_channel_branch)"
    case "$(mesh_channel_url)" in
        */archive/refs/heads/*.tar.gz)
            branch="$(mesh_channel_url)"; branch="${branch##*/heads/}"; branch="${branch%.tar.gz}" ;;
    esac
    echo "$MESH_CDN_BASE@$branch/install.sh"
}

# --- writing -------------------------------------------------------------------

# Upsert KEY=VALUE into the mesh .env; a no-op when it already holds that value.
# Sets MESH_ENV_CHANGED=1 when it wrote. Never regenerates the file: every line
# it does not name is left exactly as it is.
upsert_mesh_env() {
    local key="$1" value="$2"
    if mesh_env_has "$key" && [ "$(mesh_env_get "$key")" = "$value" ]; then
        return 0
    fi
    if [ ! -f "$MESH_ENV" ]; then
        mkdir -p "$MESH_ROOT"
        ( umask 077; : > "$MESH_ENV" )
        chown 1000:1000 "$MESH_ENV" 2>/dev/null || true
    fi
    "$MESH_ENV_MGR" set "$key" "$value" "$MESH_ENV" >/dev/null
    MESH_ENV_CHANGED=1
}

# Write the contract: the every-run keys and constants, then the seed-once keys
# that are absent. Sets MESH_ENV_CHANGED=1 when anything changed.
mesh_write_contract() {
    local key value kv
    MESH_ENV_CHANGED=0

    for key in $MESH_KEYS_EVERY_RUN; do
        value="$(ynd_source_get "$key")" || continue
        upsert_mesh_env "$key" "$value"
    done
    while IFS= read -r kv; do
        [ -n "$kv" ] || continue
        upsert_mesh_env "${kv%%=*}" "${kv#*=}"
    done < <(mesh_constants)

    # Where the owner finishes setup: the onboarding wizard on the admin app (the
    # same URL ensure-maison-onboarding.sh gates Maison to). The mesh registrar
    # hands it to every AppShield gate while Dex is absent for want of a connector
    # — an unclaimed box with Yundera Login off, or before ensure-connector-yundera.sh
    # has run — so the sign-in page links to it instead of a dead end. Derived
    # from DOMAIN, so every run like the constants.
    value="$(ynd_source_get DOMAIN 2>/dev/null || true)"
    [ -z "$value" ] || upsert_mesh_env SETUP_URL "https://admin-$value/"

    for key in $MESH_KEYS_SEED_ONCE; do
        mesh_env_has "$key" && continue
        value="$(ynd_source_get "$key")" || continue
        [ -n "$value" ] || continue
        upsert_mesh_env "$key" "$value"
    done

    # The update channel. Also replaced when it still holds a .zip: before the
    # switch this template upserted its OWN channel here every night, and the
    # mesh template only reads .tar.gz.
    case "$(mesh_env_get UPDATE_URL)" in
        ""|*.zip) upsert_mesh_env UPDATE_URL "$(mesh_channel_url)" ;;
    esac
    if ! mesh_env_has MESH_AUTO_UPDATE; then
        # "Freeze platform updates" freezes the mesh too (feature-platform-updates.sh).
        if [ "$(ynd_source_get UPDATE_URL 2>/dev/null || true)" = "frozen" ]; then
            upsert_mesh_env MESH_AUTO_UPDATE false
        else
            upsert_mesh_env MESH_AUTO_UPDATE true
        fi
    fi
    mesh_env_has SELF_CHECK_CRON || upsert_mesh_env SELF_CHECK_CRON "$MESH_SELF_CHECK_CRON_DEFAULT"
}

# --- running -------------------------------------------------------------------

# Run one mesh script under the mesh self-check's lock, so it never interleaves
# with the mesh cron (which would otherwise skip its run while this holds the
# lock — the mesh runner exits 0 on contention). Waits up to 15 minutes.
#
#   mesh_run self-check/ensure-dex.sh
mesh_run() {
    local script="$1"
    shift
    if [ ! -f "$MESH_SCRIPTS/$script" ]; then
        log_error "mesh template not installed: $MESH_SCRIPTS/$script is missing"
        return 1
    fi
    flock -w 900 "$MESH_LOCK" bash "$MESH_SCRIPTS/$script" "$@"
}

# Run the whole mesh self-check now rather than at its next cron tick. It takes
# the lock itself and exits 0 when the lock is held, so wait for a running one to
# finish first; the window between the wait and its own flock is accepted (the
# run that wins it reads the same .env).
mesh_self_check_now() {
    if [ ! -f "$MESH_SCRIPTS/self-check.sh" ]; then
        log_error "mesh template not installed: $MESH_SCRIPTS/self-check.sh is missing"
        return 1
    fi
    flock -w 900 "$MESH_LOCK" true || log_warn "a mesh self-check has held its lock for 15 minutes; running anyway"
    bash "$MESH_SCRIPTS/self-check.sh"
}
