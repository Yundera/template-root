#!/bin/bash
# Script to ensure Docker is installed and properly configured on Ubuntu systems
# Compatible with Ubuntu 20.04 LTS, 22.04 LTS, and newer versions

set -e  # Exit on any error

export DEBIAN_FRONTEND=noninteractive

USER=pcs

# Function to check if Docker is installed and working
check_docker() {
    if command -v docker >/dev/null 2>&1; then

        # Check if Docker daemon is running
        if sudo docker info >/dev/null 2>&1; then

            # Check if current user is in docker group
            if groups $USER | grep -q docker; then
                echo "Docker is properly installed and configured : $(docker --version)"
                return 0
            else
                echo "Adding user $USER to docker group"
                sudo usermod -aG docker $USER
                echo "WARNING: Please log out and log back in for group changes to take effect"
                return 0
            fi
        else
            echo "WARNING: Docker daemon not running, starting Docker service"
            sudo systemctl start docker
            sudo systemctl enable docker
        fi
    else
        return 1
    fi
}

# Function to install Docker
install_docker() {
    echo "Installing Docker..."

    # DockerUpdate package index
    sudo apt-get -qq update

    # Install prerequisites
    sudo apt-get install -qq -y ca-certificates curl

    # Create directory for keyrings
    sudo install -m 0755 -d /etc/apt/keyrings

    # Add Docker's official GPG key
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository to Apt sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # DockerUpdate package index again
    sudo apt-get -qq update

    # Install Docker packages
    echo "Installing Docker packages..."
    sudo apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group
    sudo usermod -aG docker $USER

    # Start and enable Docker service
    if [ -f /.dockerenv ]; then
        echo "Inside Docker - dev environment detected. Skipping systemctl."
    else
      sudo systemctl start docker
      sudo systemctl enable docker
    fi

    # Check Docker version
    local docker_version=$(docker --version)
    echo "Docker version: $docker_version"

    # Check Docker Compose version
    local compose_version=$(docker compose version)
    echo "Docker Compose version: $compose_version"

    echo "Docker installation completed"
}

# Main execution
if ! check_docker; then
    echo "Docker not found or not properly configured - proceeding with installation"
    install_docker

    echo "Docker has been successfully installed!"
fi