#!/bin/bash
# register-oidc-client.sh - Register an OIDC client with the local Authelia
# Usage:
#   register-oidc-client.sh <client-id> <redirect-uri> [<redirect-uri>...]
#
# Behavior:
#   - First call for a given client-id generates a random 32-byte secret, stores
#     the plaintext at /DATA/AppData/yundera/auth/clients.d/<id>.secret (chmod 600),
#     and writes an argon2id-hashed client snippet to clients.d/<id>.yml.
#   - Subsequent calls are no-ops (idempotent) — the plaintext is printed again
#     so installers can re-read it on reinstall.
#   - Re-renders Authelia configuration.yml and HUPs the container.
#
# Output:
#   On success, prints the plaintext client secret to stdout. Callers should
#   capture it and inject into the app's OIDC config (it cannot be recovered
#   from the hash).

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

# Keep stdout reserved for the plaintext secret; everything else goes to stderr
# so callers can do: SECRET=$(register-oidc-client.sh ...) cleanly.
exec 3>&1
exec 1>&2

AUTH_ROOT="/DATA/AppData/yundera/auth"
CLIENTS_DIR="$AUTH_ROOT/clients.d"
AUTHELIA_IMAGE="authelia/authelia:4.39"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <client-id> <redirect-uri> [<redirect-uri>...]" >&2
    exit 1
fi

CLIENT_ID="$1"
shift
REDIRECT_URIS=("$@")

if ! [[ "$CLIENT_ID" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "ERROR: client-id must be lowercase alphanumeric with - or _ (got: $CLIENT_ID)" >&2
    exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

SECRET_FILE="$CLIENTS_DIR/${CLIENT_ID}.secret"
CLIENT_FILE="$CLIENTS_DIR/${CLIENT_ID}.yml"

if [ -f "$SECRET_FILE" ] && [ -f "$CLIENT_FILE" ]; then
    log_info "OIDC client '$CLIENT_ID' already registered"
    cat "$SECRET_FILE" >&3
    exit 0
fi

PLAIN="$(openssl rand -hex 32 | tr -d '\n')"
HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
    authelia crypto hash generate argon2 --password "$PLAIN" 2>/dev/null \
    | awk '/^Digest:/{print $2}')"
if [ -z "$HASH" ]; then
    log_error "Failed to generate argon2 hash for client '$CLIENT_ID'"
    exit 1
fi

# Indent 8 spaces so each URI sits under "        redirect_uris:" (6-space
# list-entry indent + 2 for nested list items).
REDIRECT_YAML=""
for uri in "${REDIRECT_URIS[@]}"; do
    REDIRECT_YAML+="          - '${uri}'"$'\n'
done

TMP="$(mktemp)"
cat > "$TMP" <<EOF
      - client_id: '${CLIENT_ID}'
        client_name: '${CLIENT_ID}'
        client_secret: '${HASH}'
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        require_pkce: false
        redirect_uris:
${REDIRECT_YAML}
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
          - 'groups'
        response_types:
          - 'code'
        grant_types:
          - 'authorization_code'
          - 'refresh_token'
        token_endpoint_auth_method: 'client_secret_basic'
EOF
chmod 600 "$TMP"
mv "$TMP" "$CLIENT_FILE"

TMP="$(mktemp)"
printf '%s' "$PLAIN" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$SECRET_FILE"

log_success "Registered OIDC client: $CLIENT_ID"

# Re-render configuration.yml and HUP Authelia so the new client is live.
"$YND_ROOT/scripts/self-check/ensure-auth-secrets.sh" >/dev/null

cat "$SECRET_FILE" >&3
