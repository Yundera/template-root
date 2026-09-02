#!/bin/bash
# Provision the custom Dex frontend (theme + overlaid templates) into the dir
# the compose file bind-mounts over the stock image.
#
# WHY THIS IS A TOOL AND NOT JUST PART OF ensure-dex.sh
#
# The compose file bind-mounts templates/login.html and templates/header.html
# as individual FILES. Docker auto-creates a missing bind-mount source as a
# DIRECTORY. So ANY `docker compose up` that happens before these files exist
# leaves a directory where a file belongs, and from then on `dex` cannot start
# at all:
#
#   error mounting ".../dex-frontend/templates/login.html" to rootfs at
#   "/srv/dex/web/templates/login.html": not a directory
#
# On a cold provisioning run that is not hypothetical: ensure-admin-gate-secret.sh
# (scripts-config.txt line ~51) brings the stack up to propagate the freshly
# minted ADMIN_ASSERTION_SECRET, and it runs ~17 entries BEFORE ensure-dex.sh.
# Observed on demostaging1 2026-08-23: five failed stack-up attempts, ~6 minutes
# of backoff burned, before ensure-dex.sh finally repaired it.
#
# Hence: every caller that is about to bring the stack up runs this first. It is
# idempotent and costs two file copies.
#
# A missing source (dex-theme/ absent from the template) is not an error — Dex
# just keeps its stock UI.

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
THEME_SRC="$YND_ROOT/dex-theme"
DEX_FRONTEND="/DATA/AppData/yundera/dex-frontend"

if [ ! -d "$THEME_SRC" ]; then
    echo "dex-theme/ not found in template; Dex will use its stock login UI"
    exit 0
fi

mkdir -p "$DEX_FRONTEND/templates" "$DEX_FRONTEND/themes"

RC=0

# Copy file-by-file, clearing a DIRECTORY sitting where a file belongs. A plain
# `cp -f file dir/` will NOT fix it — cp refuses to overwrite a directory — and
# the old `2>/dev/null || true` form swallowed that refusal, so the run still
# logged "Provisioned custom Dex frontend" while leaving the PCS with no IdP and
# therefore no login of any kind.
for _src in "$THEME_SRC/templates/"*.html; do
    [ -e "$_src" ] || continue
    _dst="$DEX_FRONTEND/templates/$(basename "$_src")"
    [ -f "$_dst" ] || rm -rf "$_dst"
    if ! cp -f "$_src" "$_dst"; then
        echo "WARN: could not provision $_dst"
        RC=1
    fi
done

# Same trap for the theme, in the other direction: this one IS a directory, and
# Docker would have created it as one too, so only a stale file needs clearing.
[ -d "$DEX_FRONTEND/themes/yundera" ] || rm -f "$DEX_FRONTEND/themes/yundera"
mkdir -p "$DEX_FRONTEND/themes/yundera"

# Refresh the theme's CONTENTS in place. Do NOT `rm -rf` the directory itself:
# compose bind-mounts THIS directory into the dex container, and a bind mount
# follows the inode, not the path. Deleting and re-creating it leaves the
# running container mounted on the deleted inode — visible in the container's
# /proc/self/mountinfo as ".../themes/yundera//deleted" — so every theme/*
# asset 404s and the login page renders with static/main.css only: no
# wallpaper, no card, no logo, browser-default serif type.
#
# `docker restart dex` does NOT re-resolve a bind source, so ensure-dex.sh's
# restart at the end of its run does not repair this; only a force-recreate
# does. Since this tool runs before every stack-up, the old form re-broke the
# theme on each self-check. Observed on holyhorse + yunderalabs 2026-09-02.
#
# Emptying the directory and copying into it keeps the inode the container is
# holding, so a running dex picks the new files up with no restart at all.
find "$DEX_FRONTEND/themes/yundera" -mindepth 1 -delete 2>/dev/null || true
if ! cp -rf "$THEME_SRC/themes/yundera/." "$DEX_FRONTEND/themes/yundera/"; then
    echo "WARN: could not provision $DEX_FRONTEND/themes/yundera"
    RC=1
fi

echo "Provisioned custom Dex frontend at $DEX_FRONTEND"
exit "$RC"
