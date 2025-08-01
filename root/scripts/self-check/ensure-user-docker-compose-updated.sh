#!/bin/bash

ENV_FILE=/DATA/AppData/casaos/apps/yundera/.env
TEMPLATE_FILE=/DATA/AppData/casaos/apps/yundera/compose-template.yml
OUTPUT_FILE=/DATA/AppData/casaos/apps/yundera/docker-compose.yml

# Define required environment variables
REQUIRED_VARS=("DOMAIN" "PROVIDER_STR" "UID")

# Declare associative array to store environment variables
declare -A env_vars

# Read the environment file and store variables
while IFS='=' read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ $key =~ ^#.*$ || -z $key ]] && continue

    # Remove any surrounding quotes from the value
    value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

    # Store the key-value pair
    env_vars["$key"]="$value"

done < "$ENV_FILE"

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
    echo "Please set these variables in $ENV_FILE" >&2
    exit 1
fi

# Create a copy of the template file to work with (only after validation passes)
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Apply substitutions using the stored environment variables
for key in "${!env_vars[@]}"; do
    value="${env_vars[$key]}"
    # Replace %KEY% with value in the output file
    sed -i "s|%${key}%|${value}|g" "$OUTPUT_FILE"
done

echo "Successfully generated $OUTPUT_FILE from template using environment variables from $ENV_FILE"