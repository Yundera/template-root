#!/bin/bash
# feature-platform-updates.sh - Turn automated platform updates on or off.
#
#   status | enable | disable
#
# No new flag: UPDATE_URL in .pcs.env already decides, and ensure-template-sync.sh
# already honours it.
#
# ONE VARIABLE COVERS BOTH TEMPLATE AND IMAGES. Every platform image is pinned to
# an exact version inside the template itself (the compose files, plus KOPIA_IMAGE
# in scripts/library/kopia.sh), so the template is the version manifest. Freeze it
# and ensure-user-compose-pulled.sh keeps running but re-pulls the same tags.
#
# `frozen` VS `local`. ensure-template-sync.sh skips the download for both, but
# they mean different things and stay distinct values: `local` is a developer
# testing hand-placed scripts, `frozen` is the owner opting out. Same value for
# both and support cannot tell them apart. This script writes only `frozen`.
#
# NO APPLY STEP, unlike the other feature scripts: "apply" here would mean
# performing an update — download, migrations, stack restart — which is not what
# flipping a preference asked for. Enabling re-arms; the next self-check acts.
#
# Prints {"id","enabled"} on stdout; errors on stderr with a non-zero exit.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
PCS_ENV="$YND_ROOT/.pcs.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"
FLAG="UPDATE_URL"
STASH="UPDATE_URL_PREVIOUS"

env_get() { "$ENV_MGR" get "$1" "$PCS_ENV" 2>/dev/null || echo ""; }

emit() { printf '{"id":"platform-updates","enabled":%s}\n' "$1"; }

case "${1:-}" in
    status)
        case "$(env_get "$FLAG")" in
            frozen|local) emit false ;;
            *)            emit true ;;
        esac
        ;;
    enable)
        # Only ever undo OUR freeze. Anything else is left alone: calling enable
        # on a box that is already updating must not touch a custom UPDATE_URL,
        # and must not drag a `local` dev box back to the default.
        if [ "$(env_get "$FLAG")" = "frozen" ]; then
            previous="$(env_get "$STASH")"
            if [ -n "$previous" ]; then
                "$ENV_MGR" set "$FLAG" "$previous" "$PCS_ENV" >/dev/null
                "$ENV_MGR" delete "$STASH" "$PCS_ENV" >/dev/null 2>&1 || true
            else
                # Nothing stashed — drop the var so the template's default applies.
                "$ENV_MGR" delete "$FLAG" "$PCS_ENV" >/dev/null 2>&1 || true
            fi
        fi
        emit true
        ;;
    disable)
        # Stash whatever was there — including `local`, so freezing a dev box and
        # unfreezing it puts it back. Never stash the sentinel itself: disable is
        # idempotent, and a second call must not overwrite what the first saved.
        current="$(env_get "$FLAG")"
        if [ -n "$current" ] && [ "$current" != "frozen" ]; then
            "$ENV_MGR" set "$STASH" "$current" "$PCS_ENV" >/dev/null
        fi
        "$ENV_MGR" set "$FLAG" frozen "$PCS_ENV" >/dev/null
        emit false
        ;;
    *)
        echo "Usage: $(basename "$0") status|enable|disable" >&2
        exit 1
        ;;
esac
