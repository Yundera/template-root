#!/bin/bash
# Validate required environment variables and generate the yundera stack's .env

set -e

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/env.sh"
PCS_ENV_FILE="$YND_ROOT/.pcs.env"
SECRET_ENV_FILE="$YND_ROOT/.pcs.secret.env"
USER_ENV_FILE="$YND_ROOT/.ynd.user.env"
OUTPUT_ENV_FILE="$YND_ROOT/.env"

# Sanitize all env files before processing using unified env file manager
"$YND_TEMPLATE/scripts/tools/env-file-manager.sh" sanitize "$PCS_ENV_FILE"
"$YND_TEMPLATE/scripts/tools/env-file-manager.sh" sanitize "$SECRET_ENV_FILE"
"$YND_TEMPLATE/scripts/tools/env-file-manager.sh" sanitize "$USER_ENV_FILE"

# Define required environment variables
REQUIRED_VARS=("DOMAIN" "PROVIDER_STR" "UID")

# Declare associative array to store environment variables
declare -A env_vars

# Function to read environment file and store variables
read_env_file() {
    local file="$1"
    if [ -f "$file" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            # Skip comments and empty lines
            [[ $key =~ ^#.*$ || -z $key ]] && continue

            # Remove any surrounding quotes from the value
            value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

            # Store the key-value pair
            env_vars["$key"]="$value"

        done < "$file"
    else
        echo "Warning: Environment file not found: $file" >&2
    fi
}

# Read all three environment files
read_env_file "$PCS_ENV_FILE"
read_env_file "$SECRET_ENV_FILE"
read_env_file "$USER_ENV_FILE"

# No DEFAULT_SERVICE_HOST / _PORT defaulting here any more: the mesh template owns
# them (its install.sh seeds maison:80, Mesh Console edits them), and they reach
# this file through the read-back. A .pcs.env copy on an older box is still the
# seed-once input library/mesh.sh forwards, and nothing else.

# NOTE: no JWT_SECRET here any more. It used to be minted for the
# settings-center-app's OIDC state cookie, but that cookie — and the admin
# session cookie — are now signed with a key the app persists itself at
# /app/data/admin-session-key (src/backend/auth/sessionKey.ts), precisely so a
# container restart does not sign everyone out. Nothing reads JWT_SECRET.
# Existing hosts were cleaned by a one-shot migration, retired 2026-09-08
# (see scripts/migrations/README.md).

# Check if all required variables are set and not empty
missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${env_vars[$var]}" ]]; then
        missing_vars+=("$var")
    fi
done

# Throw error if any required variables are missing
if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "Error: The following required environment variables are not set or are empty:" >&2
    printf "  - %s\n" "${missing_vars[@]}" >&2
    echo "Please set these variables in $PCS_ENV_FILE, $SECRET_ENV_FILE, or $USER_ENV_FILE" >&2
    exit 1
fi

# Generate the .env Docker Compose reads for the yundera stack (this folder is its
# project directory): the keys docker-compose.yml interpolates, and only those —
# library/env.sh. It used to be the whole union of the three source files, so it
# carried USER_JWT, PROVIDER_STR, DEFAULT_PWD and the backup keys for a compose
# file that reads none of them. The sources above are still read whole, for the
# validation.
#
# Perms first, content second: it still carries ADMIN_ASSERTION_SECRET, and `>`
# preserves the mode of an already-existing file, which is how it once ended up
# world-readable. Created empty at 600, then filled.
: > "$OUTPUT_ENV_FILE"
chmod 600 "$OUTPUT_ENV_FILE"

{
    echo "# AUTO-GENERATED FILE - DO NOT EDIT"
    echo "# The keys docker-compose.yml interpolates, taken from:"
    echo "#   - .pcs.env, .pcs.secret.env, .ynd.user.env (later wins)"
    echo "#   - /DATA/AppData/mesh/.env (the keys the mesh template owns)"
    echo "# Any changes will be overwritten on next system update."
    echo "#"
    echo "# To modify environment variables, edit the source files above."
    echo ""
    env_emit_for_compose "$YND_ROOT/docker-compose.yml"
} > "$OUTPUT_ENV_FILE"

echo "All required environment variables are valid"
echo "Generated $OUTPUT_ENV_FILE ($(grep -c '^[A-Za-z_]' "$OUTPUT_ENV_FILE") keys)"
