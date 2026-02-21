#!/bin/bash
# env-file-manager.sh - Unified ENV file management for PCS scripts
# Usage:
#   env-file-manager.sh set VAR_NAME "value" /path/to/file.env
#   env-file-manager.sh get VAR_NAME /path/to/file.env
#   env-file-manager.sh delete VAR_NAME /path/to/file.env
#   env-file-manager.sh exists VAR_NAME /path/to/file.env
#   env-file-manager.sh sanitize /path/to/file.env

set -euo pipefail

# Print error message to stderr and exit
error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Ensure parent directory exists, create if needed
ensure_directory() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || error "Failed to create directory: $dir"
    fi
}

# Ensure file exists, create if needed
ensure_file() {
    local file="$1"
    ensure_directory "$file"
    if [ ! -f "$file" ]; then
        touch "$file" || error "Failed to create file: $file"
    fi
}

# SET: Update or add a variable in the env file
# Uses atomic write with temp file + mv for safety
cmd_set() {
    local var_name="$1"
    local var_value="$2"
    local env_file="$3"

    ensure_file "$env_file"

    local tmp_file
    tmp_file=$(mktemp) || error "Failed to create temp file"

    # Remove existing variable and write to temp file
    grep -v "^${var_name}=" "$env_file" > "$tmp_file" 2>/dev/null || true

    # Ensure trailing newline before appending
    if [ -s "$tmp_file" ] && [ "$(tail -c1 "$tmp_file" | wc -l)" -eq 0 ]; then
        echo "" >> "$tmp_file"
    fi

    # Append new value
    echo "${var_name}=${var_value}" >> "$tmp_file"

    # Atomic move
    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        error "Failed to write to $env_file"
    }

    # Verify the write
    local written_value
    written_value=$(grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")
    if [ "$written_value" != "$var_value" ]; then
        error "Verification failed: value mismatch after write to $env_file"
    fi
}

# GET: Read a variable value from the env file
# Returns empty string if not found, exits 0 on success
cmd_get() {
    local var_name="$1"
    local env_file="$2"

    if [ ! -f "$env_file" ]; then
        echo ""
        return 0
    fi

    local value
    value=$(grep "^${var_name}=" "$env_file" 2>/dev/null | head -n1 | cut -d'=' -f2- || echo "")

    # Remove surrounding quotes if present
    value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

    echo "$value"
}

# DELETE: Remove a variable from the env file
cmd_delete() {
    local var_name="$1"
    local env_file="$2"

    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp) || error "Failed to create temp file"

    # Remove the variable line
    grep -v "^${var_name}=" "$env_file" > "$tmp_file" 2>/dev/null || true

    # Atomic move
    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        error "Failed to write to $env_file"
    }
}

# EXISTS: Check if a variable exists in the env file
# Exit code 0 = exists, 1 = not found
cmd_exists() {
    local var_name="$1"
    local env_file="$2"

    if [ ! -f "$env_file" ]; then
        return 1
    fi

    if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# SANITIZE: Remove blank lines and ensure trailing newline
cmd_sanitize() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp) || error "Failed to create temp file"

    # Squeeze consecutive blank lines (like cat -s) and copy to temp
    cat -s "$env_file" > "$tmp_file"

    # Ensure trailing newline
    if [ -s "$tmp_file" ] && [ "$(tail -c1 "$tmp_file" | wc -l)" -eq 0 ]; then
        echo "" >> "$tmp_file"
    fi

    # Atomic move
    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        error "Failed to write to $env_file"
    }
}

# Main command dispatcher
main() {
    if [ $# -lt 1 ]; then
        error "Usage: env-file-manager.sh <command> [args...]"
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        set)
            if [ $# -ne 3 ]; then
                error "Usage: env-file-manager.sh set VAR_NAME value /path/to/file.env"
            fi
            cmd_set "$1" "$2" "$3"
            ;;
        get)
            if [ $# -ne 2 ]; then
                error "Usage: env-file-manager.sh get VAR_NAME /path/to/file.env"
            fi
            cmd_get "$1" "$2"
            ;;
        delete)
            if [ $# -ne 2 ]; then
                error "Usage: env-file-manager.sh delete VAR_NAME /path/to/file.env"
            fi
            cmd_delete "$1" "$2"
            ;;
        exists)
            if [ $# -ne 2 ]; then
                error "Usage: env-file-manager.sh exists VAR_NAME /path/to/file.env"
            fi
            cmd_exists "$1" "$2"
            ;;
        sanitize)
            if [ $# -ne 1 ]; then
                error "Usage: env-file-manager.sh sanitize /path/to/file.env"
            fi
            cmd_sanitize "$1"
            ;;
        *)
            error "Unknown command: $cmd. Available: set, get, delete, exists, sanitize"
            ;;
    esac
}

main "$@"
