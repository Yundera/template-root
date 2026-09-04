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
#   - seed the owner account in users_database.yml as UNCLAIMED (disabled, with
#     a throwaway hash nobody ever learns), refreshing only the email on
#     subsequent runs (Authelia owns the password once the user sets it),
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
# keeping. Losing it drops the PCS back to the UNCLAIMED state on the next run
# — the Local Account connector disappears from Dex and the owner re-claims via
# Yundera Login or over SSH (`tools/authelia-user-manager.sh claim`), so it is
# not a dead end, but back it up with the rest of /DATA/AppData/yundera.

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

# Retry budget for the two hash computations. Deliberately smaller than
# ensure-user-compose-pulled.sh's (10 attempts, up to 300s) — these are two
# sub-second container runs on the critical path of a cold provision, not a
# multi-gigabyte pull.
HASH_MAX_ATTEMPTS=5
HASH_INITIAL_BACKOFF=5
HASH_MAX_BACKOFF=60

# Digest produced by the last successful authelia_hash call. Returned this way
# rather than on stdout so the retry logging below can use log_warn like the
# rest of the script instead of having to dodge a command substitution.
AUTHELIA_HASH_RESULT=""

# authelia_hash <crypto hash generate args...>
#
# Wraps `docker run "$AUTHELIA_IMAGE"` in a retry. On a cold provision this is
# the FIRST docker run on a box whose daemon ensure-docker-installed.sh finished
# installing seconds earlier, and $AUTHELIA_IMAGE is the ONLY Docker Hub pull in
# the entire provision (every other image is ghcr.io) — two good reasons for a
# one-off failure here, and a failure here fails the whole PCS creation. The
# neighbouring docker-dependent scripts (ensure-user-compose-pulled.sh,
# ensure-user-compose-stack-up.sh) have always retried for exactly this reason;
# this one did not, and on 2026-09-03 a single `docker run` exiting 125 threw
# away an otherwise-complete demo provision.
#
# stderr is captured and logged, never discarded. Exit 125 means Docker itself
# refused to start the container, and the reason exists only on stderr — routing
# it to /dev/null (while `set -o pipefail` aborted the script through the `| awk`
# before the caller's emptiness guard could report anything) is what made that
# failure impossible to diagnose after the box was recycled.
authelia_hash() {
    local attempt=1
    local backoff="$HASH_INITIAL_BACKOFF"
    local out rc digest

    AUTHELIA_HASH_RESULT=""

    while [ "$attempt" -le "$HASH_MAX_ATTEMPTS" ]; do
        rc=0
        out="$(docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate "$@" 2>&1)" || rc=$?

        if [ "$rc" -eq 0 ]; then
            digest="$(printf '%s\n' "$out" | awk '/^Digest:/{print $2}')"
            if [ -n "$digest" ]; then
                AUTHELIA_HASH_RESULT="$digest"
                return 0
            fi
            # Ran fine but emitted no Digest line: an output-format change, which
            # no amount of retrying fixes. Still logged in full before we give up.
            log_warn "$AUTHELIA_IMAGE ran but produced no Digest line (attempt $attempt/$HASH_MAX_ATTEMPTS): $out"
        else
            log_warn "docker run $AUTHELIA_IMAGE exited $rc (attempt $attempt/$HASH_MAX_ATTEMPTS): $out"
        fi

        if [ "$attempt" -lt "$HASH_MAX_ATTEMPTS" ]; then
            sleep "$backoff"
            backoff=$((backoff * 2))
            [ "$backoff" -gt "$HASH_MAX_BACKOFF" ] && backoff="$HASH_MAX_BACKOFF"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

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
    if ! authelia_hash pbkdf2 --password "$AUTHELIA_DEX_SECRET"; then
        log_error "Failed to pbkdf2-hash AUTHELIA_DEX_SECRET via $AUTHELIA_IMAGE after $HASH_MAX_ATTEMPTS attempts"
        exit 1
    fi
    DEX_SECRET_HASH="$AUTHELIA_HASH_RESULT"
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

# The owner's Authelia username. `admin` is only the SEED placeholder: the user
# picks their own at onboarding, and `authelia-user-manager.sh claim` renames the
# entry and records the choice in LOCAL_ADMIN_USER (.pcs.env). Read it back here
# so the email refresh below tracks the right block after a rename.
#
# .pcs.env and NOT .ynd.user.env: the latter is re-fetched from the orchestrator's
# /user/info on every tick by ensure-yundera-user-data.sh, which would clobber a
# locally-chosen value. The username is host-local state.
#
# Absent = every PCS provisioned before onboarding existed, all of which have a
# literal `admin` — so the default keeps them working untouched.
AUTHELIA_ADMIN="$("$ENV_MGR" get LOCAL_ADMIN_USER "$YND_ROOT/.pcs.env")"
[ -n "$AUTHELIA_ADMIN" ] || AUTHELIA_ADMIN="admin"

# One-shot marker: a `password:` field already present means the file is SEEDED
# (by us, or by Authelia writing a password change back). In that case refresh
# only the email line — never touch the password.
#
# Seeded is not the same as CLAIMED. The unclaimed seed below also writes a
# `password:` (Authelia rejects a user without one — see the seed block), so this
# check stays a pure "has this file been written yet?" test and is unaffected by
# onboarding. Claimed-ness is `disabled` being absent/false, and the only reader
# of that is ensure-dex.sh, which uses it to decide whether the Local Account
# connector is offered at all. Do not conflate the two.
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
    # --- seed UNCLAIMED --------------------------------------------------------
    # A fresh PCS ships with NO usable local credential. The account exists but
    # is `disabled: true`, which Authelia enforces at authentication: a login
    # with the right password is refused as "user not found". The owner claims it
    # at onboarding (admin app, or `authelia-user-manager.sh claim` over SSH),
    # choosing both the username and the password.
    #
    # Two hard constraints from Authelia 4.39, both verified against the image —
    # violate either and the container dies on startup, taking every interactive
    # login on the PCS with it:
    #
    #   1. a user entry MUST carry a non-empty `password:`. Seeding the
    #      "unclaimed" state as a bare `disabled: true` with no password field
    #      is FATAL:
    #        could not validate the schema: Users.admin.users: non zero value required
    #      Hence the throwaway hash below — random, never printed, never stored
    #      anywhere else, and unusable precisely because the account is disabled.
    #   2. `users:` MUST NOT be empty, so we cannot simply omit the entry and let
    #      the claim create the first one:
    #        could not validate the schema: users: non zero value required
    #      Hence a PLACEHOLDER key, which `claim` renames to the user's choice.
    #
    # DEFAULT_PWD is deliberately NOT used here any more. It is an app-seed
    # secret — ensure-maison-app-mirror.sh injects it into every installed app as
    # default_pwd / PCS_DEFAULT_PASSWORD / APP_DEFAULT_PASSWORD — so making it
    # the PCS login password put the owner's credential in every app's env.
    if ! authelia_hash argon2 --random --random.length 64; then
        log_error "Failed to generate the unclaimed-account placeholder hash via $AUTHELIA_IMAGE after $HASH_MAX_ATTEMPTS attempts"
        exit 1
    fi
    THROWAWAY_HASH="$AUTHELIA_HASH_RESULT"

    TMP="$(mktemp)"
    cat > "$TMP" <<EOF
users:
  ${AUTHELIA_ADMIN}:
    disabled: true
    displayname: "Administrator"
    password: "${THROWAWAY_HASH}"
    email: "${ADMIN_EMAIL}"
    groups:
      - admins
EOF
    chmod 600 "$TMP"
    mv "$TMP" "$USERS_DB"
    log_success "Seeded Authelia owner account UNCLAIMED (${AUTHELIA_ADMIN}, disabled until onboarding)"
fi

# Restart Authelia if running so the re-rendered config is picked up. SIGHUP is
# NOT safe (Authelia 4.39 exits on it); docker restart is a clean SIGTERM +
# start (~3s). Silent on cold boot when the container does not exist yet.
if docker inspect authelia >/dev/null 2>&1; then
    docker restart authelia >/dev/null 2>&1 || true
fi

log_info "Authelia provisioning complete (data root: $AUTH_ROOT)"
