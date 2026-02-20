#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

# Script to ensure Ubuntu is up to date

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

# Update package list
[ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
apt-get update -qq

# Show available upgrades (optional)
apt-get list -qq --upgradable 2>/dev/null | grep upgradable || echo "All packages are up to date"