#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

# Script to ensure the host's package lists are fresh (Ubuntu or Debian —
# plain apt; the filename predates Debian support and is kept for scripts-config.txt)

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"

# Update package list
[ -x "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh"
retry_net "apt-get update" apt-get update -qq

# Show available upgrades (optional)
apt-get list -qq --upgradable 2>/dev/null | grep upgradable || echo "All packages are up to date"