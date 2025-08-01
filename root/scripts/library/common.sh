#!/bin/bash
# Common utility functions for scripts

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"

# Source the common logging utilities
source ${SCRIPT_DIR}/library/log.sh

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    exit 0
}