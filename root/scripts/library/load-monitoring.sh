#!/bin/bash
# System load monitoring and script execution functions

# =================================================================
# SYSTEM LOAD MONITORING FUNCTIONS
# =================================================================

wait_for_low_load() {
    local max_load_per_core=${1:-1.5}
    local check_interval=${2:-5}
    local cpu_cores=$(nproc)

    while true; do
        local current_load=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | xargs)

        # Simple awk-based floating point comparison (no bc dependency)
        local load_ok=$(awk -v curr="$current_load" -v cores="$cpu_cores" -v max_per_core="$max_load_per_core" \
            'BEGIN { if (curr < cores * max_per_core) print "1"; else print "0" }')

        if [[ "$load_ok" == "1" ]]; then
            break
        fi

        local threshold=$(awk -v cores="$cpu_cores" -v max_per_core="$max_load_per_core" \
            'BEGIN { printf "%.1f", cores * max_per_core }')

        log "System load too high: $current_load (threshold: $threshold), waiting $check_interval seconds..."
        sleep $check_interval
    done
}

wait_for_low_cpu() {
    local max_cpu=${1:-75}
    local check_interval=${2:-5}

    while true; do
        local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | sed 's/us//')

        # Handle case where cpu_usage might be empty or non-numeric
        if [[ -z "$cpu_usage" ]] || ! [[ "$cpu_usage" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            break
        fi

        # Use awk for floating point comparison instead of bc
        local cpu_ok=$(awk -v curr="$cpu_usage" -v max="$max_cpu" \
            'BEGIN { if (curr < max) print "1"; else print "0" }')

        if [[ "$cpu_ok" == "1" ]]; then
            break
        fi

        log "CPU usage too high: $cpu_usage% (threshold: $max_cpu%), waiting $check_interval seconds..."
        sleep $check_interval
    done
}

# Wait for disk I/O to settle
wait_for_low_io() {
    local max_io_wait=${1:-15}
    local check_interval=${2:-5}

    # Check if iostat is available
    if ! command -v iostat >/dev/null 2>&1; then
        # Fallback: check if there are many processes in D state (uninterruptible sleep)
        local d_state_procs=$(ps aux | awk '$8 ~ /D/ { count++ } END { print count+0 }')
        if [ "$d_state_procs" -gt 5 ]; then
            sleep $check_interval
        fi
        return 0
    fi

    while true; do
        local io_wait=$(iostat -c 1 2 2>/dev/null | tail -n 2 | head -n 1 | awk '{print $4}' | cut -d. -f1)
        # Handle case where io_wait might be empty
        if [[ -z "$io_wait" ]] || ! [[ "$io_wait" =~ ^[0-9]+$ ]]; then
            break
        fi

        if [ "$io_wait" -lt "$max_io_wait" ]; then
            break
        fi
        log "I/O wait too high: $io_wait% (threshold: $max_io_wait%), waiting $check_interval seconds..."
        sleep $check_interval
    done
}

# Combined system readiness check with consistent values
wait_for_system_ready() {
    local load_threshold=1.5    # Load per core
    local cpu_threshold=75      # CPU percentage
    local io_threshold=15       # I/O wait percentage
    local wait_interval=5       # Check interval in seconds

    # Force filesystem sync before checking system load
    sync

    wait_for_low_load $load_threshold $wait_interval
    wait_for_low_cpu $cpu_threshold $wait_interval
    wait_for_low_io $io_threshold $wait_interval

    # Final sync to ensure all operations are committed to disk
    sync
}

# =================================================================
# LOAD-AWARE SCRIPT EXECUTION
# =================================================================

# Execute script with load monitoring and sync
# Usage: execute_script_with_load_monitoring <script_path>
execute_script_with_load_monitoring() {
    local script_path="$1"
    local script_name=$(basename "$script_path")

    wait_for_system_ready

    # Call the execute_script_with_logging function
    execute_script_with_logging "$script_path"
    local exit_code=$?

    wait_for_system_ready

    return $exit_code
}