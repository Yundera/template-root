#!/bin/bash
# ensure-authelia.sh - Provision Authelia as the PCS local-account IdP.
#
# Authelia sits BEHIND Dex as a single OIDC connector (the "Local Account"
# login), owning the credential that used to live in CasaOS. It has exactly one
# OIDC client — Dex — so there is no dynamic client registration here (that
# stays on Dex's gRPC path). Compared with the old top-level Authelia
# deployment this script drops all of clients.d/, the concurrency flock, and
# register-oidc-client.sh.
#
# Responsibilities (all idempotent):
#   - generate-once the session/storage/reset/oidc-hmac secrets + RSA JWKS key,
#   - generate-once the Dex<->Authelia client secret (AUTHELIA_DEX_SECRET):
#     plaintext into .pcs.secret.env + the unified .env (Dex reads it to render
#     its connector), pbkdf2 hash cached for Authelia's client config,
#   - render configuration.yml every run (tracks DOMAIN; re-emits the always-
#     present single-client identity_providers block),
#   - seed the admin user in users_database.yml from DEFAULT_PWD,
#     refreshing only the email on subsequent runs (Authelia owns the password
#     once the user changes it),
#   - restart authelia so a re-rendered config is picked up.
#
# Storage layout (host /DATA/AppData/yundera/auth/, mounted at /config):
#   secrets/{session,storage,reset,oidc-hmac}  generate-once (chmod 600)
#   secrets/dex-client-hash                     pbkdf2 hash of AUTHELIA_DEX_SECRET
#   oidc/private.pem                            RSA-4096 JWKS signing key
#   configuration.yml                           rendered each run
#   users_database.yml                          file user store (Authelia owns it after seed)
#   db.sqlite                                   Authelia session/regulation store
#
# RECOVERY: unlike the Dex dir, this holds the local account and IS worth
# keeping. Losing it resets the local password to DEFAULT_PWD on the next run
# (the user can also recover via the email reset flow), so it is not a dead end,
# but back it up with the rest of /DATA/AppData/yundera.

set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"
source "$YND_ROOT/scripts/library/log.sh"

AUTH_ROOT="/DATA/AppData/yundera/auth"
SECRETS_DIR="$AUTH_ROOT/secrets"
OIDC_DIR="$AUTH_ROOT/oidc"
TEMPLATE="$YND_ROOT/auth/configuration.yml.tmpl"
CONFIG_OUT="$AUTH_ROOT/configuration.yml"
USERS_DB="$AUTH_ROOT/users_database.yml"
DEX_HASH_FILE="$SECRETS_DIR/dex-client-hash"

SECRET_ENV="$YND_ROOT/.pcs.secret.env"
USER_ENV="$YND_ROOT/.ynd.user.env"
UNIFIED_ENV="$YND_ROOT/.env"
ENV_MGR="$YND_ROOT/scripts/tools/env-file-manager.sh"

# Single image for both hashes: argon2 (user password) + pbkdf2 (client secret).
AUTHELIA_IMAGE="authelia/authelia:4.39"

mkdir -p "$SECRETS_DIR" "$OIDC_DIR"
chmod 700 "$SECRETS_DIR"

DOMAIN="$("$ENV_MGR" get DOMAIN "$USER_ENV")"
if [ -z "$DOMAIN" ]; then
    log_error "DOMAIN not set in $USER_ENV; cannot render Authelia config"
    exit 1
fi

# --- generate-once secrets ---------------------------------------------------
# Referenced by docker-compose via *_FILE env vars + the OIDC HMAC (inlined into
# configuration.yml).
for name in session storage reset oidc-hmac; do
    if [ ! -f "$SECRETS_DIR/$name" ]; then
        openssl rand -hex 32 > "$SECRETS_DIR/$name"
        chmod 600 "$SECRETS_DIR/$name"
        log_info "Generated Authelia secret: $name"
    fi
done

# RSA-4096 keypair for OIDC JWKS signing.
if [ ! -f "$OIDC_DIR/private.pem" ]; then
    openssl genrsa -out "$OIDC_DIR/private.pem" 4096 2>/dev/null
    chmod 600 "$OIDC_DIR/private.pem"
    log_info "Generated Authelia OIDC JWKS keypair"
fi

# --- Dex<->Authelia client secret -------------------------------------------
# Generate-once. Dex (the client) needs the PLAINTEXT; Authelia (the provider)
# stores only a pbkdf2 hash. The plaintext lives in .pcs.secret.env and is
# folded into the unified .env so the SAME cycle's Dex render (ensure-dex.sh,
# which runs right after this script) can interpolate it into the connector.
AUTHELIA_DEX_SECRET="$("$ENV_MGR" get AUTHELIA_DEX_SECRET "$SECRET_ENV")"
if [ -z "$AUTHELIA_DEX_SECRET" ]; then
    AUTHELIA_DEX_SECRET="$(openssl rand -hex 32)"
    "$ENV_MGR" set AUTHELIA_DEX_SECRET "$AUTHELIA_DEX_SECRET" "$SECRET_ENV"
    rm -f "$DEX_HASH_FILE"   # force a fresh hash for the new secret
    log_info "Generated AUTHELIA_DEX_SECRET (Dex<->Authelia connector secret)"
fi
"$ENV_MGR" set AUTHELIA_DEX_SECRET "$AUTHELIA_DEX_SECRET" "$UNIFIED_ENV"

# pbkdf2 hash of the client secret, cached (generate-once alongside the secret).
if [ ! -f "$DEX_HASH_FILE" ]; then
    DEX_SECRET_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate pbkdf2 --password "$AUTHELIA_DEX_SECRET" 2>/dev/null \
        | awk '/^Digest:/{print $2}')"
    if [ -z "$DEX_SECRET_HASH" ]; then
        log_error "Failed to pbkdf2-hash AUTHELIA_DEX_SECRET via $AUTHELIA_IMAGE"
        exit 1
    fi
    printf '%s' "$DEX_SECRET_HASH" > "$DEX_HASH_FILE"
    chmod 600 "$DEX_HASH_FILE"
fi
DEX_SECRET_HASH="$(cat "$DEX_HASH_FILE")"

# --- render configuration.yml ------------------------------------------------
# Base (everything above identity_providers) via envsubst for ${DOMAIN} only,
# then append the always-present single-client OIDC block. The pbkdf2 hash and
# the PEM hold '$' sequences envsubst would mangle, so they are injected here as
# bash variable values inside the heredoc (never through envsubst).
TMP="$(mktemp)"
chmod 600 "$TMP"
export DOMAIN
envsubst '${DOMAIN}' < "$TEMPLATE" > "$TMP"

HMAC="$(cat "$SECRETS_DIR/oidc-hmac")"
JWKS_KEY="$(sed 's/^/          /' "$OIDC_DIR/private.pem")"
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
      - client_id: 'dex'
        client_name: 'Dex (PCS SSO broker)'
        client_secret: '${DEX_SECRET_HASH}'
        public: false
        authorization_policy: 'one_factor'
        # Dex is a trusted first-party broker (it runs its own skipApprovalScreen),
        # so never show Authelia's consent screen for it.
        consent_mode: 'implicit'
        redirect_uris:
          - 'https://auth-${DOMAIN}/callback'
        # 'groups' carries each user's users_database.yml groups through to Dex,
        # which forwards them to the admin dashboard (insecureEnableGroups in
        # dex.config.yaml.tmpl). That claim is the ONLY thing distinguishing an
        # admin from a plain local account — drop it and every user gets the
        # full dashboard, including the terminal. Authelia serves it from
        # userinfo rather than the ID token by default, which is what Dex's
        # getUserInfo: true is for; no claims_policy is needed.
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
          - 'groups'
        userinfo_signed_response_alg: 'none'
        token_endpoint_auth_method: 'client_secret_basic'
EOF

mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"
log_info "Rendered Authelia config at $CONFIG_OUT"

# --- seed / refresh the admin user ------------------------------------------
# Operator email from .ynd.user.env — the password-reset recovery address, so
# it must track EMAIL even after the initial seed. admin@$DOMAIN is an unrouted
# vanity fallback.
ADMIN_EMAIL="$("$ENV_MGR" get EMAIL "$USER_ENV")"
if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${DOMAIN}"
    log_warn "EMAIL not set in $USER_ENV; falling back to ${ADMIN_EMAIL}"
fi

# Authelia's admin username is fixed to 'admin' — a single well-known local
# login. (This used to be qualified with "regardless of DEFAULT_USER", which
# named the host/CasaOS user; CasaOS is gone and nothing reads that var any
# more, so it was dropped from .pcs.env.)
AUTHELIA_ADMIN="admin"

# One-shot marker: a `password:` field already present means the file is seeded
# (by us, or by Authelia writing a password change back). In that case refresh
# only the email line — never touch the password.
#
# The rewrite is SCOPED TO THE ADMIN'S BLOCK. users_database.yml is no longer
# guaranteed to hold exactly one user, so the previous unanchored
# /^[[:space:]]+email:/ rule was a latent data-loss bug: it stamped the
# operator's address onto EVERY user in the file, on every self-check tick,
# silently redirecting each of their password-reset mails to the admin.
# Block tracking is by indent — the first key under `users:` establishes the
# per-user indent, keys at that indent switch blocks, and only deeper `email:`
# keys inside the admin's own block are rewritten.
if [ -f "$USERS_DB" ] && grep -q "^[[:space:]]*password:" "$USERS_DB"; then
    TMP="$(mktemp)"
    awk -v admin="$AUTHELIA_ADMIN" -v new="$ADMIN_EMAIL" '
        BEGIN { in_users = 0; user_indent = -1; in_admin = 0 }
        # `users:` opens the map; any other column-0 key closes it.
        /^users:[[:space:]]*$/ { in_users = 1; print; next }
        /^[^[:space:]#]/       { in_users = 0; user_indent = -1; in_admin = 0; print; next }
        in_users && match($0, /^[[:space:]]+/) {
            indent = RLENGTH
            key = $0
            sub(/^[[:space:]]+/, "", key)
            sub(/:.*$/, "", key)
            if (key != "") {
                if (user_indent == -1) user_indent = indent
                if (indent == user_indent) in_admin = (key == admin)
                else if (in_admin && key == "email") {
                    printf "%s%s: \"%s\"\n", substr($0, 1, indent), "email", new
                    next
                }
            }
        }
        { print }
    ' "$USERS_DB" > "$TMP"
    if cmp -s "$TMP" "$USERS_DB"; then
        rm -f "$TMP"
        log_info "users_database.yml already seeded; admin email already ${ADMIN_EMAIL}"
    else
        chmod 600 "$TMP"
        mv "$TMP" "$USERS_DB"
        log_info "users_database.yml already seeded; refreshed admin email to ${ADMIN_EMAIL}"
    fi
else
    # AUTHELIA_ADMIN is set above the branch — the refresh path needs it too.
    DEFAULT_PWD="$("$ENV_MGR" get DEFAULT_PWD "$SECRET_ENV")"
    if [ -z "$DEFAULT_PWD" ]; then
        log_error "DEFAULT_PWD not set in $SECRET_ENV; cannot seed Authelia admin. Run scripts/tools/generate-default-pwd.sh, then re-run."
        exit 1
    fi

    ADMIN_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate argon2 --password "$DEFAULT_PWD" 2>/dev/null \
        | awk '/^Digest:/{print $2}')"
    if [ -z "$ADMIN_HASH" ]; then
        log_error "Failed to argon2-hash the admin password via $AUTHELIA_IMAGE"
        exit 1
    fi

    TMP="$(mktemp)"
    cat > "$TMP" <<EOF
users:
  ${AUTHELIA_ADMIN}:
    displayname: "Administrator"
    password: "${ADMIN_HASH}"
    email: "${ADMIN_EMAIL}"
    groups:
      - admins
EOF
    chmod 600 "$TMP"
    mv "$TMP" "$USERS_DB"
    log_success "Seeded Authelia admin user: ${AUTHELIA_ADMIN}"
fi

# Restart Authelia if running so the re-rendered config is picked up. SIGHUP is
# NOT safe (Authelia 4.39 exits on it); docker restart is a clean SIGTERM +
# start (~3s). Silent on cold boot when the container does not exist yet.
if docker inspect authelia >/dev/null 2>&1; then
    docker restart authelia >/dev/null 2>&1 || true
fi

log_info "Authelia provisioning complete (data root: $AUTH_ROOT)"
