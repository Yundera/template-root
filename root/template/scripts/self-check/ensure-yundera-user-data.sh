#!/bin/bash

# ensure-yundera-user-data.sh - Make sure the box holds its identity
# (USER_JWT, PROVIDER_STR, UID, DOMAIN, EMAIL), pcs-orchestrator
# doc/identity-push.md. Three ways to get it, tried in order; the identity is
# critical path (no DOMAIN, no mesh, no box), so the slower ones stay as
# fallbacks rather than being removed.
#
# 0. Nothing to do: a pushed RS256 USER_JWT with more than 2 days left and the
#    identity it came with mean the operator is keeping this box current.
# 1. Doorbell reply: ring the doorbell with a one-time key and get the identity
#    back in the answer (`yundera-admin identity-fetch` from the admin-app
#    image, in the host's network namespace). No credential and no listener
#    needed, so it works on a wiped box and on a box being provisioned, before
#    Caddy or the admin app exist. Needs Docker (this step runs after
#    ensure-docker-installed.sh) and an admin-app pin with identity-fetch.
# 2. Push: ring the plain doorbell and wait for the push to land through the
#    admin app. Not during provisioning — nothing on the box can receive it yet.
# 3. Pull: GET ${OPERATOR_API}/user/info with the stored USER_JWT. Restores
#    PROVIDER_STR, UID, DOMAIN and EMAIL, never renews USER_JWT. Kept for an
#    operator without doorbell replies.
#
# OPERATOR_API comes from .pcs.env (bare orchestrator base, no /user), default
# https://app.yundera.com/service/pcs.

set -euo pipefail

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
SECRET_ENV_FILE="$YND_ROOT/.pcs.secret.env"
USER_ENV_FILE="$YND_ROOT/.ynd.user.env"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"

# Read Yundera API base from PCS env file or use default
OPERATOR_API=$("$YND_TEMPLATE/scripts/tools/env-file-manager.sh" get OPERATOR_API "$PCS_ENV_FILE")

if [ -z "$OPERATOR_API" ]; then
    OPERATOR_API="https://app.yundera.com/service/pcs"
    echo "Using default OPERATOR_API: $OPERATOR_API"
else
    echo "Using configured OPERATOR_API: $OPERATOR_API"
fi

# Create user env file if it doesn't exist
if [ ! -f "$USER_ENV_FILE" ]; then
    echo "Creating new user env file at $USER_ENV_FILE"
    touch "$USER_ENV_FILE"
    chmod 644 "$USER_ENV_FILE"
fi

# A wiped box may have lost it; the push recreates the contents.
if [ ! -f "$SECRET_ENV_FILE" ]; then
    install -m 600 /dev/null "$SECRET_ENV_FILE"
fi

source "$YND_TEMPLATE/scripts/library/identity.sh"

ENV_MGR="$YND_TEMPLATE/scripts/tools/env-file-manager.sh"

# True when the box holds a fresh pushed token and the identity it came with.
identity_complete() {
    identity_token_fresh "$("$ENV_MGR" get USER_JWT "$SECRET_ENV_FILE")" \
        && [ -n "$("$ENV_MGR" get PROVIDER_STR "$SECRET_ENV_FILE")" ] \
        && [ -n "$("$ENV_MGR" get UID "$USER_ENV_FILE")" ] \
        && [ -n "$("$ENV_MGR" get DOMAIN "$USER_ENV_FILE")" ]
}

if identity_complete; then
    echo "Identity delivered by push, token valid until $(date -u -d "@$(jwt_exp "$("$ENV_MGR" get USER_JWT "$SECRET_ENV_FILE")")" '+%Y-%m-%d %H:%M UTC')"
    exit 0
fi

# --- 1. Doorbell reply -------------------------------------------------------

# The first admin-app release with `identity-fetch`. An older image would start
# its web server on the host network instead of running the subcommand.
IDENTITY_FETCH_MIN_VERSION="2.2.0"

# The admin-app image the yundera stack pins (root docker-compose.yml).
admin_app_image() {
    grep -oE 'ghcr\.io/yundera/settings-center-app:[^[:space:]"'"'"']+' "$YND_ROOT/docker-compose.yml" 2>/dev/null | head -n1
}

identity_fetch_supported() {
    local tag="${1##*:}"
    [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    [ "$(printf '%s\n%s\n' "$IDENTITY_FETCH_MIN_VERSION" "${BASH_REMATCH[0]}" | sort -V | head -n1)" = "$IDENTITY_FETCH_MIN_VERSION" ]
}

# Ask once. Exit status: 0 applied, 3 the operator had nothing for us, other
# a failure. The identity only goes through apply-identity.sh's stdin.
identity_reply_once() {
    local image="$1" bundle rc
    set +e
    bundle=$(timeout 90 docker run --rm --network host --pull never "$image" \
        identity-fetch --api "$OPERATOR_API" --issuer "$TRUST_ISSUER")
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$bundle" | "$YND_TEMPLATE/scripts/tools/apply-identity.sh" >/dev/null
}

identity_reply() {
    command -v docker >/dev/null 2>&1 || { echo "Doorbell reply skipped: Docker is not installed"; return 1; }
    local image
    image=$(admin_app_image)
    if [ -z "$image" ] || ! identity_fetch_supported "$image"; then
        echo "Doorbell reply skipped: admin-app pin '${image:-none}' predates identity-fetch ($IDENTITY_FETCH_MIN_VERSION)"
        return 1
    fi
    local i
    for i in 1 2 3; do
        docker image inspect "$image" >/dev/null 2>&1 && break
        docker pull -q "$image" >/dev/null 2>&1 && break
        echo "Pulling $image failed (attempt $i)"
        sleep 5
    done
    docker image inspect "$image" >/dev/null 2>&1 || { echo "Doorbell reply skipped: cannot pull $image"; return 1; }

    # 3 = no reply. During a create the operator's host index can lag the claim
    # by up to a minute, so ask a few times before falling back.
    local rc
    for i in 1 2 3 4 5; do
        if identity_reply_once "$image"; then
            return 0
        else
            rc=$?
        fi
        [ "$rc" -eq 3 ] || { echo "Doorbell reply failed (exit $rc)"; return 1; }
        [ "$i" -lt 5 ] && sleep 20
    done
    echo "Doorbell answered without an identity"
    return 1
}

TRUST_ISSUER=$("$ENV_MGR" get TRUST_ISSUER "$PCS_ENV_FILE" 2>/dev/null || true)

if identity_reply && identity_complete; then
    echo "Identity delivered by doorbell reply"
    exit 0
fi

# --- 2. Push -----------------------------------------------------------------

# The operator answers the doorbell asynchronously, through the admin app; a
# push takes seconds. It rate-limits rings per IP, so a ring at boot followed
# by this one is fine: this loop sees the push the first ring caused. At boot
# that first push often finds the stack not serving yet; the operator retries it
# after 20, 60 and 120 s more (about 20, 80 and 200 s after the first attempt),
# so wait long enough to see the last retry land.
if [ "${PCS_PROVISIONING:-0}" = "1" ]; then
    echo "Provisioning: no receiver on the box yet, skipping the push wait"
elif identity_ring_doorbell "$OPERATOR_API"; then
    for _ in $(seq 1 48); do
        sleep 5
        if identity_complete; then
            echo "Identity delivered by push"
            exit 0
        fi
    done
    echo "Doorbell rang, no push arrived within 240s; falling back to pull"
else
    echo "Doorbell at ${OPERATOR_API}/identity/doorbell did not answer 204 (operator without identity push, or unreachable); falling back to pull"
fi

# --- 3. Pull -----------------------------------------------------------------

# Read USER_JWT from secret env file
USER_JWT=$("$ENV_MGR" get USER_JWT "$SECRET_ENV_FILE")

if [ -z "$USER_JWT" ]; then
    echo "ERROR: USER_JWT not found in $SECRET_ENV_FILE and no identity was pushed. The operator pushes on its next refresh, or run \`pcs identity push\` for this PCS."
    exit 1
fi

echo "Found USER_JWT (${#USER_JWT} chars), fetching user data from ${OPERATOR_API}/user/info"

# Make API call to fetch user info from configured API endpoint
HTTP_RESPONSE=$(curl -s -w "HTTPSTATUS:%{http_code}" \
    -H "Authorization: Bearer $USER_JWT" \
    -H "Content-Type: application/json" \
    -X GET \
    "${OPERATOR_API}/user/info" || echo "HTTPSTATUS:000")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS:[0-9]*$//')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: Failed to fetch user data. HTTP status: $HTTP_CODE, Response: $HTTP_BODY"
    exit 1
fi

# Parse JSON response using basic shell tools (avoid jq dependency)
# Extract values using grep and sed
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | sed "s/\"$key\":\"\([^\"]*\)\"/\1/" || echo ""
}

# Extract user data from response
RECV_UID=$(extract_json_value "$HTTP_BODY" "uid")
RECV_EMAIL=$(extract_json_value "$HTTP_BODY" "email")
RECV_DOMAIN=$(extract_json_value "$HTTP_BODY" "domain")
RECV_PROVIDER_STR=$(extract_json_value "$HTTP_BODY" "domainSignature")
RECV_USER_JWT=$(extract_json_value "$HTTP_BODY" "userJWT")

# Update secret environment variables (sensitive data)
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set PROVIDER_STR "$RECV_PROVIDER_STR" "$SECRET_ENV_FILE"
# An operator that minted nothing must not wipe the token the box holds.
if [ -n "$RECV_USER_JWT" ]; then
    $YND_TEMPLATE/scripts/tools/env-file-manager.sh set USER_JWT "$RECV_USER_JWT" "$SECRET_ENV_FILE"
fi

# Update user environment variables (less sensitive data)
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set UID "$RECV_UID" "$USER_ENV_FILE"
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set DOMAIN "$RECV_DOMAIN" "$USER_ENV_FILE"

# Update email from API response (from Firebase Auth)
$YND_TEMPLATE/scripts/tools/env-file-manager.sh set EMAIL "$RECV_EMAIL" "$USER_ENV_FILE"

# Ensure proper permissions
chmod 600 "$SECRET_ENV_FILE"  # Restrictive permissions for secrets
chmod 644 "$USER_ENV_FILE"    # Standard permissions for user data

echo "Successfully updated secret and user data files (UID=$RECV_UID, DOMAIN=$RECV_DOMAIN)"