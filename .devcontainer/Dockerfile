FROM ubuntu:24.04

# Avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    automake \
    autoconf \
    cmake \
    git \
    curl \
    wget \
    unzip \
    pkg-config \
    libssl-dev \
    libncurses5-dev \
    inotify-tools \
    ripgrep \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN id ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu \
    && mkdir -p /workspaces && chown ubuntu:ubuntu /workspaces

USER ubuntu

# Install mise
RUN curl https://mise.run | sh
ENV PATH="/home/ubuntu/.local/bin:${PATH}"

RUN mise settings set experimental true

WORKDIR /workspaces
