#!/bin/bash
# ensure-auth-secrets.sh - Generate Authelia secrets, JWKS, and render configuration
# Idempotent: existing secrets/files are never overwritten. Re-renders the
# Authelia configuration.yml on every run so newly-registered OIDC clients
# (dropped into clients.d/) are picked up.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

AUTH_ROOT="/DATA/AppData/yundera/auth"
SECRETS_DIR="$AUTH_ROOT/secrets"
OIDC_DIR="$AUTH_ROOT/oidc"
CLIENTS_DIR="$AUTH_ROOT/clients.d"
TEMPLATE="$YND_ROOT/auth/configuration.yml.tmpl"
CONFIG_OUT="$AUTH_ROOT/configuration.yml"
USERS_DB="$AUTH_ROOT/users_database.yml"

PCS_ENV="$YND_ROOT/.pcs.env"
SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

AUTHELIA_IMAGE="authelia/authelia:4.39"

mkdir -p "$SECRETS_DIR" "$OIDC_DIR" "$CLIENTS_DIR"
chmod 700 "$SECRETS_DIR"

# Secrets referenced by docker-compose via *_FILE env vars + the OIDC HMAC
# (inlined into configuration.yml). Generate-once.
for name in session storage reset oidc-hmac; do
    if [ ! -f "$SECRETS_DIR/$name" ]; then
        openssl rand -hex 32 > "$SECRETS_DIR/$name"
        chmod 600 "$SECRETS_DIR/$name"
        log_info "Generated Authelia secret: $name"
    fi
done

# RSA-4096 keypair for OIDC JWKS signing. Generate-once.
if [ ! -f "$OIDC_DIR/private.pem" ]; then
    openssl genrsa -out "$OIDC_DIR/private.pem" 4096 2>/dev/null
    chmod 600 "$OIDC_DIR/private.pem"
    log_info "Generated Authelia OIDC JWKS keypair"
fi

# Render base configuration.yml from template (envsubst for ${DOMAIN} only).
DOMAIN="$("$ENV_MGR" get DOMAIN "$USER_ENV")"
if [ -z "$DOMAIN" ]; then
    log_error "DOMAIN not set in $USER_ENV; cannot render Authelia config"
    exit 1
fi

TMP="$(mktemp)"
export DOMAIN
envsubst '${DOMAIN}' < "$TEMPLATE" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$CONFIG_OUT"

# Append identity_providers (OIDC) block ONLY if at least one client is
# registered. Authelia 4.38+ fails startup on an empty `clients: []` list,
# so on a fresh PCS (no apps yet) the OIDC section is omitted entirely.
# Each file in clients.d/*.yml is a YAML list entry starting with
# "- client_id: ..." indented 6 spaces.
if ls "$CLIENTS_DIR"/*.yml >/dev/null 2>&1; then
    HMAC="$(cat "$SECRETS_DIR/oidc-hmac")"
    JWKS_KEY="$(sed 's/^/          /' "$OIDC_DIR/private.pem")"
    CLIENTS_BLOCK="$(cat "$CLIENTS_DIR"/*.yml)"
    cat >> "$CONFIG_OUT" <<EOF

identity_providers:
  oidc:
    hmac_secret: '${HMAC}'
    jwks:
      - key_id: 'yundera-pcs'
        algorithm: 'RS256'
        use: 'sig'
        key: |
${JWKS_KEY}
    clients:
${CLIENTS_BLOCK}
EOF
    log_info "Rendered Authelia config with $(ls "$CLIENTS_DIR"/*.yml | wc -l) OIDC client(s)"
else
    log_info "No OIDC clients registered; Authelia config rendered without identity_providers block"
fi

# Ensure users_database.yml exists (Authelia's file auth backend requires it
# even when empty). Seed admin user ONLY on first run when both DEFAULT_USER
# and DEFAULT_PWD are set; otherwise leave the file empty and let the admin
# manage users manually. Presence of any `password:` field is the one-shot
# marker — once set (either by our seed or by Authelia writing changes back),
# we never overwrite.
if [ ! -f "$USERS_DB" ]; then
    echo "users: {}" > "$USERS_DB"
    chmod 600 "$USERS_DB"
fi

if grep -q "^[[:space:]]*password:" "$USERS_DB"; then
    log_info "users_database.yml has existing users, skipping admin seed"
else
    DEFAULT_USER="$("$ENV_MGR" get DEFAULT_USER "$PCS_ENV")"
    DEFAULT_PWD="$("$ENV_MGR" get DEFAULT_PWD "$SECRET_ENV")"
    if [ -z "$DEFAULT_USER" ] || [ -z "$DEFAULT_PWD" ]; then
        log_warn "DEFAULT_USER or DEFAULT_PWD not set; Authelia started with an empty users_database.yml. Set both in env files (or add users via Authelia) to enable login."
    else
        ADMIN_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
            authelia crypto hash generate argon2 --password "$DEFAULT_PWD" 2>/dev/null \
            | awk '/^Digest:/{print $2}')"
        if [ -z "$ADMIN_HASH" ]; then
            log_error "Failed to generate argon2 hash via $AUTHELIA_IMAGE; leaving users_database.yml empty"
        else
            TMP="$(mktemp)"
            cat > "$TMP" <<EOF
users:
  ${DEFAULT_USER}:
    displayname: "Administrator"
    password: "${ADMIN_HASH}"
    email: "admin@${DOMAIN}"
    groups:
      - admins
EOF
            chmod 600 "$TMP"
            mv "$TMP" "$USERS_DB"
            log_success "Seeded Authelia admin user: ${DEFAULT_USER}"
        fi
    fi
fi

# HUP Authelia if it's already running so the re-rendered config is picked up.
# Silent on cold boot when the container doesn't exist yet.
if docker inspect authelia >/dev/null 2>&1; then
    docker kill -s HUP authelia >/dev/null 2>&1 || true
fi

log_info "Authelia secrets and configuration ready at $AUTH_ROOT"
