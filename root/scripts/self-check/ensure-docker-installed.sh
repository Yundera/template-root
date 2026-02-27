#!/bin/bash
# Script to ensure Docker is installed and properly configured on Ubuntu systems
# Compatible with Ubuntu 20.04 LTS, 22.04 LTS, and newer versions

set -e  # Exit on any error

export DEBIAN_FRONTEND=noninteractive

USER=pcs
YND_ROOT="/DATA/AppData/casaos/apps/yundera"

# Function to check if Docker is installed and working
check_docker() {
    if command -v docker >/dev/null 2>&1; then

        # Check if Docker daemon is running
        if docker info >/dev/null 2>&1; then

            # Check if current user is in docker group
            if groups $USER | grep -q docker; then
                echo "✓ Docker is properly installed and configured : $(docker --version)"
                return 0
            else
                echo "→ Adding user $USER to docker group"
                usermod -aG docker $USER
                echo "WARNING: Please log out and log back in for group changes to take effect"
                return 0
            fi
        else
            echo "→ Docker daemon not running, starting Docker service"
            systemctl start docker
            systemctl enable docker
        fi
    else
        return 1
    fi
}

# Function to install Docker
install_docker() {
    echo "→ Installing Docker..."

    # Install prerequisites
    "$YND_ROOT/scripts/tools/ensure-packages.sh" ca-certificates curl

    # Create directory for keyrings
    install -m 0755 -d /etc/apt/keyrings

    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository to Apt sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index again
    [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
    apt-get -qq update >/dev/null

    # Install Docker packages
    if ! { DEBIAN_FRONTEND=noninteractive apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; } >/dev/null 2>&1; then
        echo "✗ Docker package installation failed. Running with verbose output for debugging:"
        [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        exit 1
    fi

    # Add current user to docker group
    usermod -aG docker $USER

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