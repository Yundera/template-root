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

# Serialize concurrent invocations. register-oidc-client.sh calls this script
# at the end of every registration, so N near-simultaneous app installs fan out
# into N concurrent renders. Without a lock, two interleaved runs can either
# (a) both append identity_providers to the same file, producing a duplicate
# key that crashes Authelia, or (b) one run's stale read of clients.d/ wins
# the final mv and silently drops a freshly-registered client.
exec 9>"$AUTH_ROOT/.lock"
flock 9

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

# Build the full config (template + optional identity_providers block) into a
# tempfile and mv it into place in a single atomic step. Earlier versions used
# mv-then-append, which left a window where the file existed without its
# identity_providers block — anything reading it during that window (Authelia
# on restart, or a parallel render) would see an incomplete config.
TMP="$(mktemp)"
chmod 600 "$TMP"
export DOMAIN
envsubst '${DOMAIN}' < "$TEMPLATE" > "$TMP"

# Append identity_providers (OIDC) block ONLY if at least one client is
# registered. Authelia 4.38+ fails startup on an empty `clients: []` list,
# so on a fresh PCS (no apps yet) the OIDC section is omitted entirely.
# Each file in clients.d/*.yml is a YAML list entry starting with
# "- client_id: ..." indented 6 spaces.
if ls "$CLIENTS_DIR"/*.yml >/dev/null 2>&1; then
    HMAC="$(cat "$SECRETS_DIR/oidc-hmac")"
    JWKS_KEY="$(sed 's/^/          /' "$OIDC_DIR/private.pem")"
    CLIENTS_BLOCK="$(cat "$CLIENTS_DIR"/*.yml)"
    cat >> "$TMP" <<EOF

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

mv "$TMP" "$CONFIG_OUT"

# Seed admin user. Authelia 4.38+ requires users_database.yml to contain at
# least one user (empty `users: {}` fails the startup schema check), so we
# only write the file after we can produce a valid entry.
#
# One-shot marker: presence of any `password:` field in an existing file
# (either from our seed or from Authelia writing password changes back).
if [ -f "$USERS_DB" ] && grep -q "^[[:space:]]*password:" "$USERS_DB"; then
    log_info "users_database.yml has existing users, skipping admin seed"
else
    DEFAULT_USER="$("$ENV_MGR" get DEFAULT_USER "$PCS_ENV")"
    DEFAULT_PWD="$("$ENV_MGR" get DEFAULT_PWD "$SECRET_ENV")"

    # DEFAULT_USER is documented as optional in .pcs.env.example. When unset,
    # fall back to 'admin' so Authelia always has a seedable username.
    if [ -z "$DEFAULT_USER" ]; then
        DEFAULT_USER="admin"
        log_info "DEFAULT_USER not set; using '${DEFAULT_USER}' as Authelia admin username"
    fi

    if [ -z "$DEFAULT_PWD" ]; then
        log_error "DEFAULT_PWD not set in $SECRET_ENV; cannot seed Authelia admin. Run scripts/tools/generate-default-pwd.sh, then re-run this script."
        exit 1
    fi

    ADMIN_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate argon2 --password "$DEFAULT_PWD" 2>/dev/null \
        | awk '/^Digest:/{print $2}')"
    if [ -z "$ADMIN_HASH" ]; then
        log_error "Failed to generate argon2 hash via $AUTHELIA_IMAGE"
        exit 1
    fi

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

# Restart Authelia if it's already running so the re-rendered config is picked up.
# SIGHUP is not safe here — Authelia 4.39 treats SIGHUP as "reopen log files"
# and empirically exits on it (observed on holyhorse 2026-04-21, exit code 2
# with no log line). docker restart sends SIGTERM for a graceful shutdown and
# then starts again; ~3s downtime but the new config is loaded correctly.
# Silent on cold boot when the container doesn't exist yet.
if docker inspect authelia >/dev/null 2>&1; then
    docker restart authelia >/dev/null 2>&1 || true
fi

log_info "Authelia secrets and configuration ready at $AUTH_ROOT"
