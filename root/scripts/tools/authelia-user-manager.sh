#!/bin/bash
# authelia-user-manager.sh - CRUD for Authelia's file-backend user store.
#
# Usage:
#   authelia-user-manager.sh list
#   authelia-user-manager.sh add <username> <displayname> <email> [groups-csv]
#   authelia-user-manager.sh delete <username>
#   authelia-user-manager.sh set-password <username>
#   authelia-user-manager.sh set-email <username> <email>
#
# STDOUT IS A MACHINE INTERFACE. Every subcommand prints JSON and nothing else;
# all diagnostics go to stderr. The settings-center-app dashboard shells out to
# this over SSH (`sudo -n authelia-user-manager.sh ...`) and parses stdout, the
# same way default-app.ts drives env-file-manager.sh.
#
#   list                    -> [{"username","displayname","email","groups":[]}]
#   add / set-password      -> {"username","password"}   <- plaintext, shown ONCE
#   delete / set-email      -> {"username"}
#
# Passwords are never accepted as input and never appear in argv: `authelia
# crypto hash generate argon2 --random` mints the password inside the container
# and prints both it and its digest. The CLI refuses piped stdin ("you must
# either use an interactive terminal or use the --password flag"), and --password
# would put the secret in the host's process list, so --random is the only way to
# get a hash without exposing one. It also happens to be exactly the product
# behaviour we want: the dashboard shows a generated password once.
#
# Why a host script rather than YAML-in-the-dashboard: the file is 0600 and
# root-owned, Authelia rewrites it itself on password change, and the flock below
# is only meaningful on the host where the file lives. Same reasoning that moved
# env-file mutation into env-file-manager.sh.

set -euo pipefail

AUTH_ROOT="/DATA/AppData/yundera/auth"
USERS_DB="$AUTH_ROOT/users_database.yml"
LOCK_FILE="$AUTH_ROOT/.users-db.lock"

# Must stay in sync with AUTHELIA_IMAGE in self-check/ensure-authelia.sh — both
# hash with the same binary, and a version skew there would mean two different
# argon2 parameter sets in one users_database.yml.
AUTHELIA_IMAGE="authelia/authelia:4.39"

# The seeded operator account. Deleting it is unrecoverable: the seed branch in
# ensure-authelia.sh is guarded by a FILE-level check (`grep -q "password:"`), so
# with any other user still present it will not re-seed, and the box is left with
# no way back into the dashboard.
PROTECTED_USER="admin"
ADMIN_GROUP="admins"

error() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- preconditions -----------------------------------------------------------

command -v yq >/dev/null 2>&1 || error "yq not found (installed by self-check/ensure-common-tools-installed.sh)"
command -v docker >/dev/null 2>&1 || error "docker not found"
[ -f "$USERS_DB" ] || error "$USERS_DB does not exist; run self-check/ensure-authelia.sh first"
[ -r "$USERS_DB" ] || error "$USERS_DB is not readable (run this via sudo)"

# Serialise the whole read-modify-write. Authelia writes this file too, on
# password change and on the email reset flow.
exec 9>"$LOCK_FILE"
flock 9 || error "Failed to acquire lock on $LOCK_FILE"

# --- helpers -----------------------------------------------------------------

# mktemp yields 0600 owned by the caller; on same-fs mv the destination inherits
# that. Capture before, restore after, so the file's mode/owner survive. Same
# idiom as env-file-manager.sh.
preserve_meta() {
    local file="$1"
    [ -e "$file" ] || { echo ""; return 0; }
    stat -c '%a:%U:%G' "$file" 2>/dev/null || echo ""
}

restore_meta() {
    local file="$1" meta="$2"
    [ -z "$meta" ] && return 0
    [ -e "$file" ] || return 0
    local mode rest owner group
    mode="${meta%%:*}"
    rest="${meta#*:}"
    owner="${rest%%:*}"
    group="${rest#*:}"
    chmod "$mode" "$file" 2>/dev/null || true
    chown "$owner:$group" "$file" 2>/dev/null || true
}

# Username becomes a YAML key AND an OIDC preferred_username, so keep it to a
# conservative charset. Leading digit rejected so yq never sees it as a number.
validate_username() {
    local u="$1"
    [ -n "$u" ] || error "username must not be empty"
    [ "${#u}" -le 32 ] || error "username must be 32 characters or fewer"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || error "invalid username '$u' (allowed: lowercase letter or underscore, then lowercase alphanumerics, '-' or '_')"
}

validate_email() {
    local e="$1"
    [ -n "$e" ] || error "email must not be empty"
    [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || error "invalid email '$e'"
}

user_exists() {
    local u="$1"
    U="$u" yq -e '.users | has(strenv(U))' "$USERS_DB" >/dev/null 2>&1
}

require_user() {
    user_exists "$1" || error "no such user: $1"
}

# Count users carrying ADMIN_GROUP, so the last one can never be removed.
admin_count() {
    G="$ADMIN_GROUP" yq '[.users[] | select((.groups // []) | contains([strenv(G)]))] | length' "$USERS_DB"
}

is_admin_user() {
    local u="$1"
    U="$u" G="$ADMIN_GROUP" yq -e '.users[strenv(U)].groups // [] | contains([strenv(G)])' "$USERS_DB" >/dev/null 2>&1
}

# Generate a password + argon2 digest inside the Authelia container. Sets the
# globals GEN_PASSWORD and GEN_DIGEST. See the header note on --random.
generate_password_and_digest() {
    local out
    out="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate argon2 \
        --random --random.length 24 --random.charset alphanumeric 2>/dev/null)" \
        || error "Failed to run $AUTHELIA_IMAGE to generate a password"

    GEN_PASSWORD="$(printf '%s' "$out" | awk '/^Random Password:/{print $3}')"
    GEN_DIGEST="$(printf '%s' "$out" | awk '/^Digest:/{print $2}')"

    [ -n "$GEN_PASSWORD" ] || error "Could not parse generated password from authelia output"
    [ -n "$GEN_DIGEST" ] || error "Could not parse argon2 digest from authelia output"
}

# Apply a yq expression to a temp copy, sanity-check it, then swap it in.
# Never edits USERS_DB in place: a yq failure partway through would otherwise
# leave the only copy of the local account store truncated.
write_users_db() {
    local expr="$1"
    local meta tmp
    meta="$(preserve_meta "$USERS_DB")"
    tmp="$(mktemp)" || error "Failed to create temp file"

    if ! yq "$expr" "$USERS_DB" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "yq failed to apply the change"
    fi

    # Refuse to install a file that lost the users map or came out empty.
    if ! yq -e '.users | type == "!!map"' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        error "refusing to write: result has no valid .users map"
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$USERS_DB" || { rm -f "$tmp"; error "Failed to write $USERS_DB"; }
    restore_meta "$USERS_DB" "$meta"
}

# --- subcommands -------------------------------------------------------------

# Password hashes are deliberately not included — this payload reaches a browser.
cmd_list() {
    yq -o=json -I=0 '
        .users
        | to_entries
        | map({
            "username": .key,
            "displayname": (.value.displayname // ""),
            "email": (.value.email // ""),
            "groups": (.value.groups // [])
          })
    ' "$USERS_DB"
}

cmd_add() {
    local username="${1:-}" displayname="${2:-}" email="${3:-}" groups_csv="${4:-users}"

    validate_username "$username"
    [ -n "$displayname" ] || error "displayname must not be empty"
    validate_email "$email"
    user_exists "$username" && error "user already exists: $username"

    [ -n "$groups_csv" ] || groups_csv="users"

    generate_password_and_digest

    # style="double" on every string field is not cosmetic. displayname is
    # user-supplied, and yq emits new values as plain scalars — a display name of
    # `Yes`, `No` or `123` would then be read back as a boolean or a number
    # rather than a string, by yq and by Authelia alike. Quoting also keeps the
    # file uniform with what ensure-authelia.sh seeds.
    U="$username" DN="$displayname" EM="$email" PW="$GEN_DIGEST" GR="$groups_csv" \
        write_users_db '
            .users[strenv(U)] = {
                "displayname": strenv(DN),
                "password": strenv(PW),
                "email": strenv(EM),
                "groups": (strenv(GR) | split(",") | map(sub("^\s+|\s+$"; "")) | map(select(. != "")))
            }
            | .users[strenv(U)].displayname style="double"
            | .users[strenv(U)].password style="double"
            | .users[strenv(U)].email style="double"
            | .users[strenv(U)].groups[] style="double"
        '

    user_exists "$username" || error "verification failed: $username missing after write"

    U="$username" P="$GEN_PASSWORD" yq -o=json -I=0 -n \
        '{"username": strenv(U), "password": strenv(P)}'
}

cmd_delete() {
    local username="${1:-}"

    validate_username "$username"
    require_user "$username"

    [ "$username" = "$PROTECTED_USER" ] \
        && error "refusing to delete '$PROTECTED_USER': it is the seeded operator account and ensure-authelia.sh will not re-seed it while other users exist"

    if is_admin_user "$username" && [ "$(admin_count)" -le 1 ]; then
        error "refusing to delete the last member of '$ADMIN_GROUP' — the dashboard would become unreachable"
    fi

    U="$username" write_users_db 'del(.users[strenv(U)])'

    user_exists "$username" && error "verification failed: $username still present after delete"

    U="$username" yq -o=json -I=0 -n '{"username": strenv(U)}'
}

cmd_set_password() {
    local username="${1:-}"

    validate_username "$username"
    require_user "$username"

    generate_password_and_digest

    U="$username" PW="$GEN_DIGEST" write_users_db \
        '.users[strenv(U)].password = strenv(PW) | .users[strenv(U)].password style="double"'

    U="$username" P="$GEN_PASSWORD" yq -o=json -I=0 -n \
        '{"username": strenv(U), "password": strenv(P)}'
}

cmd_set_email() {
    local username="${1:-}" email="${2:-}"

    validate_username "$username"
    require_user "$username"
    validate_email "$email"

    # The operator account's address is owned by .ynd.user.env, not by this
    # file: ensure-authelia.sh re-stamps it from EMAIL on every self-check tick
    # (that is what the admin-scoped awk in it exists to do). Accepting a change
    # here would look like it worked and silently revert within the hour, so
    # refuse and say where the real setting lives.
    [ "$username" = "$PROTECTED_USER" ] \
        && error "'$PROTECTED_USER' email is managed by EMAIL in .ynd.user.env and is re-applied on every self-check; change it there instead"

    U="$username" EM="$email" write_users_db \
        '.users[strenv(U)].email = strenv(EM) | .users[strenv(U)].email style="double"'

    U="$username" yq -o=json -I=0 -n '{"username": strenv(U)}'
}

# --- dispatch ----------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
Usage:
  authelia-user-manager.sh list
  authelia-user-manager.sh add <username> <displayname> <email> [groups-csv]
  authelia-user-manager.sh delete <username>
  authelia-user-manager.sh set-password <username>
  authelia-user-manager.sh set-email <username> <email>
EOF
    exit 1
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift

case "$COMMAND" in
    list)         [ $# -eq 0 ] || usage; cmd_list ;;
    add)          [ $# -ge 3 ] && [ $# -le 4 ] || usage; cmd_add "$@" ;;
    delete)       [ $# -eq 1 ] || usage; cmd_delete "$@" ;;
    set-password) [ $# -eq 1 ] || usage; cmd_set_password "$@" ;;
    set-email)    [ $# -eq 2 ] || usage; cmd_set_email "$@" ;;
    *)            usage ;;
esac
