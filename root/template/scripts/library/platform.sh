#!/bin/bash
# Host platform: which distros a PCS may run on, and the few places they differ.
#
# Supported: Ubuntu (every PCS created before Debian support, kept as is) and
# Debian (new PCS). Both are apt/dpkg/systemd, and on Contabo both images come up
# the same way — cloud-init, netplan + systemd-networkd + systemd-resolved,
# unattended-upgrades enabled, a cloud-init default user at UID 1000. Only what
# is listed here differs; branch on these helpers, never on a raw os-release read.
#
# Checked on Contabo images: Ubuntu 24.04 (holyhorse) and Debian 13 (2026-11-20).

# os-release is read in a subshell: sourcing it here would overwrite NAME, ID,
# VERSION… in the caller's shell.
_platform_field() {
    ( . /etc/os-release 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" )
}

PLATFORM_ID="$(_platform_field ID)"
PLATFORM_VERSION="$(_platform_field VERSION_ID)"
PLATFORM_CODENAME="$(_platform_field VERSION_CODENAME)"

# 0 when this host runs a distro the template supports.
platform_is_supported() {
    case "$PLATFORM_ID" in
        ubuntu|debian) return 0 ;;
        *)             return 1 ;;
    esac
}

# Base URL of Docker's apt repository for this distro (…/linux/ubuntu, …/linux/debian).
platform_docker_repo_url() {
    echo "https://download.docker.com/linux/${PLATFORM_ID}"
}

# 0 when the distro ships sshd socket-activated by default.
#
# Ubuntu does since 22.10 (ssh.socket enabled, ssh.service disabled). Debian ships
# an ssh.socket unit too but leaves it disabled and runs ssh.service. ensure-ssh.sh
# keeps each distro on its own default rather than converting Debian to a model
# that was only ever exercised on Ubuntu.
platform_ssh_socket_is_default() {
    [ "$PLATFORM_ID" = "ubuntu" ]
}
