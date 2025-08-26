#!/bin/bash

# Default log file path
DEFAULT_LOG_FILE="/DATA/AppData/casaos/apps/yundera/log/yundera.log"

# Set log file (can be overridden by calling scripts)
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"

# Enhanced logging function with multiple features
log() {
    local level="INFO"
    local message=""
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_to_file=true
    local log_to_stdout=true

    # Parse arguments - support both old and new calling styles
    if [ $# -eq 1 ]; then
        # Single argument - assume it's just the message (backwards compatibility)
        message="$1"
    elif [ $# -eq 2 ]; then
        # Two arguments - level and message
        level="$1"
        message="$2"
    else
        # Multiple arguments - level and message parts
        level="$1"
        shift
        message="$*"
    fi

    # Format the log entry
    local log_entry="[$timestamp] [$level] $message"

    # Output to stdout (always)
    if [ "$log_to_stdout" = true ]; then
        echo "$message"
    fi

    # Output to log file (check if file exists or can be created)
    if [ "$log_to_file" = true ]; then
        # Create log directory if it doesn't exist
        local log_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$log_dir" ]; then
            mkdir -p "$log_dir" 2>/dev/null || true
        fi

        # Write to log file
        echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Internal logging function that only writes to log file (no stdout)
log_to_file_only() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] $message"

    # Create log directory if it doesn't exist
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi

    # Write to log file only
    echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
}

# Convenience functions for different log levels
log_info() {
    log "INFO" "$*"
}

log_success() {
    log "SUCCESS" "$*"
}

log_warn() {
    log "WARN" "$*"
}

log_error() {
    log "ERROR" "$*"
}

log_debug() {
    # Only log debug messages if DEBUG environment variable is set
    if [ "${DEBUG:-false}" = "true" ]; then
        log "DEBUG" "$*"
    fi
}

# Function to set a custom log file for the current script
set_log_file() {
    LOG_FILE="$1"
    log_info "Log file set to: $LOG_FILE"
}

# =================================================================
# SCRIPT EXECUTION FUNCTIONS
# =================================================================

# Function to execute a script with logging
# Usage: execute_script_with_logging <script_path>
execute_script_with_logging() {
    local script_path="$1"
    local script_name=$(basename "$script_path")

    cd "$(dirname "$script_path")" || {
        log_error "Failed to change directory to $(dirname "$script_path")"
        return 1
    }

    # Validate input
    if [ -z "$script_path" ]; then
        log_error "No script path provided"
        return 1
    fi

    if [ ! -f "$script_path" ]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    if [ ! -x "$script_path" ]; then
        log_error "Script is not executable: $script_path"
        return 1
    fi

    # Log start
    log_info "=== $script_name : Starting  ==="

    # Execute script with real-time output and logging
    # Use stdbuf to disable buffering for real-time output
    {
        if command -v stdbuf >/dev/null 2>&1; then
            stdbuf -oL -eL "$script_path" 2>&1
        else
            "$script_path" 2>&1
        fi
    } | while IFS= read -r line; do
        # Display to stdout immediately
        echo "$line"
        # Log to file only (no stdout to avoid recursion)
        log_to_file_only "OUTPUT" "$line"
    done

    # Capture the exit code from the script (not the while loop)
    local exit_code=${PIPESTATUS[0]}

    # Log result
    if [ "$exit_code" -eq 0 ]; then
        log_success "=== $script_name : success ==="
    else
        log_error "=== $script_name : failed (exit code: $exit_code) ==="
    fi

    return "$exit_code"
}

