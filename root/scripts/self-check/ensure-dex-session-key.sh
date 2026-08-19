#!/bin/bash
# ensure-dex-session-key.sh - Mint the AES key Dex uses to encrypt its session
# cookie.
#
# WHY THERE IS A DEX SESSION AT ALL, AS OF 2026-08
#
# Dex v2.45.1 held no browser session: it re-ran its connector on every
# /authorize and advertised no logout of any kind. That is why the PCS grew a
# connector-stickiness hack in caddy/Caddyfile and why "log out" could not
# actually log anyone out — see SSO-LOGOUT-PLAN.md §9.1.
#
# Upstream fixed this: RP-Initiated Logout (PR #4674) and Back-Channel Logout
# with a `sid` claim (PR #4945) are merged. With DEX_SESSIONS_ENABLED=true Dex
# keeps a real `dex_session` cookie and advertises `end_session_endpoint` plus
# `backchannel_logout_supported`, which is what lets one logout end every app's
# session through the spec instead of through bespoke plumbing.
#
# WHAT THIS KEY IS
#
# `sessions.cookieEncryptionKey` — AES, and Dex accepts ONLY 16, 24 or 32 bytes
# (AES-128/192/256). We mint 32 raw bytes. Note this is a *byte length* limit,
# not a string-format one: `openssl rand -hex 32` would be 64 characters and is
# rejected, so this uses base64 of 24 bytes, which is exactly 32 ASCII chars.
#
# Leaving it empty is legal (cookies then go unencrypted) but the cookie carries
# session state to a browser, so it gets encrypted.
#
# MUST RUN BEFORE ensure-dex.sh, which interpolates ${DEX_SESSION_KEY} into the
# rendered config. Unset renders an empty key: Dex still starts and sessions
# still work, they are merely unencrypted — it fails soft, not closed, which is
# why this is ordered rather than guarded.
#
# ROTATION invalidates every live Dex session, i.e. it costs one round of
# re-logins across every app on the box. Safe at any time.
#
# RECOVERY: nothing to back up. A lost key is re-minted on the next run.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

DEX_SESSION_KEY="$("$ENV_MGR" get DEX_SESSION_KEY "$SECRET_ENV")"
if [ -z "$DEX_SESSION_KEY" ]; then
    # 24 random bytes -> 32 base64 characters -> AES-256. Base64 of 24 bytes has
    # no '=' padding and no '$', so it survives the envsubst pass in
    # ensure-dex.sh unchanged.
    DEX_SESSION_KEY="$(openssl rand -base64 24)"
    "$ENV_MGR" set DEX_SESSION_KEY "$DEX_SESSION_KEY" "$SECRET_ENV"
    log_info "Generated DEX_SESSION_KEY (Dex session cookie encryption)"
fi

# Mirrored on every run, not only on creation: ensure-env-vars-valid.sh rebuilds
# the unified .env from its sources, so a key minted after that rebuild would
# otherwise be missing from the file compose reads. Same shape as
# ensure-admin-gate-secret.sh.
"$ENV_MGR" set DEX_SESSION_KEY "$DEX_SESSION_KEY" "$UNIFIED_ENV"

# No stack recreation here, unlike ensure-admin-gate-secret.sh. Nothing in
# docker-compose.yml interpolates this value — it reaches Dex through the config
# file that ensure-dex.sh renders, and that script already restarts dex when the
# rendered config changes. Adding a recreate here would fight it.

log_success "Dex session key is in place"
