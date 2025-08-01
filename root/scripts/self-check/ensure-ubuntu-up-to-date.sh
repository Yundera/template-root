#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

# Script to ensure Ubuntu is up to date

# DockerUpdate package list
apt-get update -qq

# Show available upgrades (optional)
apt-get list -qq --upgradable 2>/dev/null | grep upgradable || echo "All packages are up to date"