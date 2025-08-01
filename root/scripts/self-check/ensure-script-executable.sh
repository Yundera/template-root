#!/bin/bash

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"
count=0

# Make all script files executable and owned
while read script; do
    chmod +x "$script"
    chown pcs:pcs "$script"
    ((count++))
done < <(find ${SCRIPT_DIR} -type f -exec grep -l '^#!/' {} \;)

echo "Total files changed: $count"