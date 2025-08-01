#!/bin/bash

set -e

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
source "${SCRIPT_DIR}/library/common.sh"

# Check if at least one argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <script_to_execute> [additional_args...]"
    exit 1
fi

# Execute and explicitly capture/return the exit code
execute_script_with_logging "$1" "$@"
exit_code=$?
exit $exit_code