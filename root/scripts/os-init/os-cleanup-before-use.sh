#!/bin/bash

set -e  # Exit on any error

# Clean command history
echo "Cleaning command history..."
# Clear root user history
cat /dev/null > /root/.bash_history
# Clear history for all other users
for user_home in /home/*; do
  if [ -d "$user_home" ]; then
    cat /dev/null > "$user_home/.bash_history" 2>/dev/null
  fi
done

# Clear history in memory for current session
history -c

# clean up logfile
echo "" > /DATA/AppData/casaos/apps/yundera/log/yundera.log

# Log successful execution
echo "$(date): os-init-cleanup executed successfully" >> "/DATA/AppData/casaos/apps/yundera/log/yundera.log"