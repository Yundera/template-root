#!/bin/bash
# ensure-casadash-yundera-mirror.sh - Project the `yundera` stack into CasaDash's layout.
#
# Writes:
#     /DATA/AppData/yundera/docker-compose.yml   copy of the template's own compose
#     /DATA/AppData/yundera/.env                 copy of the unified .env
#     /DATA/AppData/yundera/.casaos-mirror       provenance marker
#
# WHY: CasaDash already tiles the stack — it finds it over the Docker socket via the
# `com.docker.compose.project.working_dir` label and renders the x-compose-app block
# as the "Settings" tile. But that is an UNMANAGED tile: isManaged() is literally
# stat(AppsDir()/<project>/docker-compose.yml) (internal/apps/apps.go), and the stack's
# compose lives at /DATA/AppData/casaos/apps/yundera — two levels under CasaDash's
# AppsDir (/DATA/AppData), so its managedDirs() scan never sees it. The tile therefore
# offers only logs + stats, with no Env / Compose / Override / WebUI tabs. Placing the
# compose at /DATA/AppData/yundera is the whole fix.
#
# This is the same promotion ensure-casadash-app-mirror.sh performs for CasaOS apps,
# but it cannot live in that script's loop: that loop materialises the environment
# CasaOS *injects* into an app at up-time, whereas this stack is interpolated from the
# unified .env (DOMAIN, PROVIDER_STR, DEFAULT_SERVICE_HOST, PUBLIC_IP_DASH …) that
# ensure-env-vars-valid.sh assembles. Different source of truth, so: different script.
# ensure-casadash-app-mirror.sh explicitly skips `yundera` and must keep doing so.
#
# NO TILE IS DUPLICATED. Registry.List runs the managed pass first and marks the
# project `seen`; the unmanaged (Docker-discovered) pass then skips it. The tile just
# changes character.
#
# THIS SCRIPT NEVER RUNS `docker compose up`. ensure-user-compose-stack-up.sh remains
# the sole owner of bringing the stack up, from $YND_ROOT — never from the mirror.
#
# COPY, NOT HARDLINK — same reasoning as ensure-casadash-app-mirror.sh: CasaDash's
# Normalize() does os.WriteFile() on a managed app's compose before every up, which
# through a shared inode would rewrite the template's live copy at $YND_ROOT.
#
# CONSEQUENCE OF PROMOTING, ACCEPTED: a managed tile is one CasaDash may `compose up`
# itself — a user pressing Start/Restart, or Republish() after a domain change, brings
# the stack up from /DATA/AppData/yundera. The project name is pinned by `name: yundera`
# inside the compose file, so this reconciles the SAME project rather than creating a
# second one, and both directories render identically (asserted below). What it does do
# is flip the working_dir label until the next ensure-user-compose-stack-up.sh flips it
# back: container churn, not data loss. Identical to the trade-off doc/casadash-migration.md
# §1.3 accepts for every mirrored CasaOS app. Uninstall is not a risk — `yundera` is in
# the casadash stack's PROTECTED_APPS.
set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
DST_DIR="/DATA/AppData/yundera"
SRC_COMPOSE="$YND_ROOT/docker-compose.yml"
UNIFIED_ENV="$YND_ROOT/.env"
DST_COMPOSE="$DST_DIR/docker-compose.yml"
DST_ENV="$DST_DIR/.env"
MARKER="$DST_DIR/.casaos-mirror"

source "$YND_ROOT/scripts/library/log.sh"

if [ ! -f "$SRC_COMPOSE" ]; then
    log_error "Stack compose not found: $SRC_COMPOSE"
    exit 1
fi
if [ ! -f "$UNIFIED_ENV" ]; then
    log_error "Unified .env not found: $UNIFIED_ENV (ensure-env-vars-valid.sh must run first)"
    exit 1
fi

# $DST_DIR always exists already — it is the stack's own data root (dex/, auth/,
# data/certs/, the provisioning marker). Adding the compose next to the data is exactly
# CasaDash's flat layout. What we must not do is clobber a compose we did not write:
# one present WITHOUT our marker means something else owns this folder.
if [ -f "$DST_COMPOSE" ] && [ ! -f "$MARKER" ]; then
    log_error "$DST_COMPOSE exists but carries no $MARKER — refusing to overwrite"
    exit 1
fi

mkdir -p "$DST_DIR"

# --- compose file (write only on change, to keep mtimes stable) ---
if ! cmp -s "$SRC_COMPOSE" "$DST_COMPOSE"; then
    cp "$SRC_COMPOSE" "$DST_COMPOSE"
    chmod 644 "$DST_COMPOSE"
    log_info "Updated $DST_COMPOSE from $SRC_COMPOSE"
fi

# --- .env: the unified .env, verbatim ---
# Copied wholesale rather than cherry-picked, for the same reason deploy-stack.sh does
# it: a variable added to any of .pcs.env / .pcs.secret.env / .ynd.user.env then reaches
# the mirror with no change here. It carries DEFAULT_PWD, PROVIDER_STR and USER_JWT, so
# it is chmod 600 exactly as its source is.
TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"
{
    echo "# AUTO-GENERATED FILE - DO NOT EDIT"
    echo "# Copy of $UNIFIED_ENV, written by scripts/self-check/ensure-casadash-yundera-mirror.sh"
    echo "# so CasaDash renders this stack's compose exactly as the template does."
    echo "# Regenerated on every self-check; edit the sources instead:"
    echo "#   $YND_ROOT/{.pcs.env,.pcs.secret.env,.ynd.user.env}"
    echo ""
    cat "$UNIFIED_ENV"
} > "$TMP_ENV"

if ! cmp -s "$TMP_ENV" "$DST_ENV"; then
    mv "$TMP_ENV" "$DST_ENV"
    chmod 600 "$DST_ENV"
    log_info "Regenerated $DST_ENV"
else
    rm -f "$TMP_ENV"
fi

echo "mirrored by ensure-casadash-yundera-mirror.sh" > "$MARKER"

# /DATA is owned by pcs:pcs (uid/gid 1000); keep the mirror readable by the casadash
# container (PUID/PGID 1000), as ensure-casadash-app-mirror.sh does for CasaOS apps.
chown 1000:1000 "$DST_COMPOSE" "$DST_ENV" "$MARKER" 2>/dev/null || true

# --- verification: both directories must render the same stack ---
# This is the property the promotion rests on: CasaDash may `compose up` from the
# mirror, so a mirror that renders differently would silently give the PCS a different
# container spec than ensure-user-compose-stack-up.sh does.
#
# HERMETIC (`env -i`) on both sides — the same reasoning as ensure-casadash-app-mirror.sh:
# an interactive `sudo` self-check carries a rich environment and the 3am cron carries
# almost none, so an inherited variable would make drift appear or vanish depending on
# who ran the check rather than on the mirror being wrong. Both sides get their values
# from the .env in their own project directory, which is the thing under test.
render() {
    local dir="$1"
    env -i PATH="$PATH" HOME="${HOME:-/root}" \
        docker compose --project-directory "$dir" -f "$dir/docker-compose.yml" config 2>/dev/null
}

# The compose plugin is installed by ensure-docker-installed.sh, which runs long before
# this, and ensure-user-compose-stack-up.sh could not have brought the stack up without
# it — so on a real PCS it is always here. The dev container (dev/) carries the docker
# CLI without the plugin, though, and the files above are already correct by then: skip
# the assertion rather than fail a self-check over a missing verification tool.
if ! docker compose version >/dev/null 2>&1; then
    log_warn "docker compose unavailable — skipping the yundera mirror render check"
    exit 0
fi

# Capture rather than diff <(…): a compose that fails to render produces EMPTY output,
# and two empty renders compare equal — a vacuous pass.
src_render="$(render "$YND_ROOT" || true)"
mirror_render="$(render "$DST_DIR" || true)"

if [ -z "$src_render" ]; then
    log_error "MIRROR_DRIFT: yundera: $YND_ROOT does not render — the stack's own compose is broken"
    exit 1
fi
if [ "$src_render" != "$mirror_render" ]; then
    log_error "MIRROR_DRIFT: yundera: mirrored render differs from $YND_ROOT render"
    exit 1
fi

log_info "CasaDash yundera mirror: $DST_DIR is in sync"
exit 0
