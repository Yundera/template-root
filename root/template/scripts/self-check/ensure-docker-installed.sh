#!/bin/bash
# Script to ensure Docker is installed and properly configured.
# Installs from Docker's own apt repository for the host distro (Ubuntu or
# Debian, see library/platform.sh).

set -e  # Exit on any error

export DEBIAN_FRONTEND=noninteractive

# Both pcs and admin need docker group membership. pcs is the operator
# account; admin is the sudoer the settings-center-app SSHes in as for
# `docker compose …` calls (DockerUpdate.ts, etc.) without per-command sudo.
DOCKER_USERS=(pcs admin)
YND_ROOT="/DATA/AppData/yundera"
YND_TEMPLATE="$YND_ROOT/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/platform.sh"

ensure_users_in_docker_group() {
    for u in "${DOCKER_USERS[@]}"; do
        if id "$u" >/dev/null 2>&1 && ! id -nG "$u" | tr ' ' '\n' | grep -qx docker; then
            echo "→ Adding user $u to docker group"
            usermod -aG docker "$u"
        fi
    done
}

# Function to check if Docker is installed and working
check_docker() {
    if command -v docker >/dev/null 2>&1; then

        # Check if Docker daemon is running
        if docker info >/dev/null 2>&1; then
            ensure_users_in_docker_group
            echo "✓ Docker is properly installed and configured : $(docker --version)"
            return 0
        else
            echo "→ Docker daemon not running, starting Docker service"
            systemctl start docker
            systemctl enable docker
        fi
    else
        return 1
    fi
}

install_docker_packages_verbose() {
    [ -x "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh"
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Function to install Docker
install_docker() {
    echo "→ Installing Docker..."

    # Install prerequisites
    "$YND_TEMPLATE/scripts/tools/ensure-packages.sh" ca-certificates curl

    # Create directory for keyrings
    install -m 0755 -d /etc/apt/keyrings

    # Docker publishes one repository per distro; the codename only exists in
    # the matching one (trixie under /debian, noble under /ubuntu).
    if ! platform_is_supported || [ -z "$PLATFORM_CODENAME" ]; then
        echo "✗ Unsupported host platform '${PLATFORM_ID:-unknown} ${PLATFORM_VERSION}' — cannot pick a Docker repository"
        exit 1
    fi
    local repo
    repo="$(platform_docker_repo_url)"

    # Add Docker's official GPG key
    retry_net "Docker GPG key download" curl -fsSL --max-time 60 "$repo/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository to Apt sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $repo \
      $PLATFORM_CODENAME stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index again
    [ -x "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh"
    retry_net "apt-get update (Docker repo)" apt-get -qq update >/dev/null

    # Install Docker packages
    if ! { DEBIAN_FRONTEND=noninteractive apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; } >/dev/null 2>&1; then
        # The retry decides, not the first attempt: an apt/dpkg lock taken between
        # the update above and the install fails the quiet run and is gone by the
        # time this one starts. Exiting 1 after a retry that installed Docker
        # failed the whole provisioning of a box that was in fact fine.
        # A mirror dropping a .deb mid-download fails it the same way, so the verbose
        # retry repeats (update + install) with backoff, each attempt logged as WARN.
        echo "✗ Quiet Docker package installation failed. Retrying with verbose output..."
        if ! RETRY_NET_ATTEMPTS=4 retry_net "Docker packages install" install_docker_packages_verbose; then
            echo "✗ Failed to install Docker packages"
            exit 1
        fi
    fi

    # Add operator + admin to docker group
    ensure_users_in_docker_group

    # Start and enable Docker service
    if [ -f /.dockerenv ]; then
        echo "→ Inside Docker - dev environment detected. Skipping systemctl."
    else
      systemctl start docker
      systemctl enable docker
    fi

    # Check Docker version
    local docker_version=$(docker --version)

    # Check Docker Compose version
    local compose_version=$(docker compose version)
    echo "✓ Docker installation completed - (Docker Compose version: $compose_version, Docker version: $docker_version)"
}

# Main execution
if ! check_docker; then
    echo "→ Docker not found or not properly configured - proceeding with installation"
    install_docker

    echo "✓ Docker ready"
fi