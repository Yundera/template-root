FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install common tools needed by template scripts
RUN apt-get update && apt-get install -y \
    wget \
    unzip \
    rsync \
    htop \
    curl \
    bash \
    apt-utils \
    && rm -rf /var/lib/apt/lists/*

# Install yq (YAML processor)
ARG YQ_VERSION=v4.44.1
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) YQ_BINARY="yq_linux_amd64" ;; \
        arm64) YQ_BINARY="yq_linux_arm64" ;; \
        armhf) YQ_BINARY="yq_linux_arm" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Create directory structure matching PCS
RUN mkdir -p /DATA/AppData/casaos/apps/yundera \
    && mkdir -p /DATA/AppData/casaos/apps/yundera/migration-markers \
    && mkdir -p /DATA/AppData/casaos/apps/yundera/log

WORKDIR /DATA/AppData/casaos/apps/yundera
