#!/bin/bash
# Script to ensure common tools are installed
export DEBIAN_FRONTEND=noninteractive

apt-get install -qq -y wget unzip rsync htop isc-dhcp-client

echo "Common tools are installed"