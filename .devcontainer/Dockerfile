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
    ca-certificates \
    gnupg \
    pkg-config \
    libssl-dev \
    libncurses5-dev \
    inotify-tools \
    ripgrep \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install PostgreSQL 18 + pgvector from the PGDG apt repo. This is the app's
# vector store (Postgres + pgvector, HNSW index). We install the server here —
# rather than via a devcontainer feature — so we get the exact major (18) WITH
# pgvector, owning the standard port 5432. postgresql-18 pulls in its own
# matching client (postgresql-client-18).
RUN install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y postgresql-18 postgresql-18-pgvector && \
    rm -rf /var/lib/apt/lists/*

RUN id ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu \
    && mkdir -p /workspaces && chown ubuntu:ubuntu /workspaces

USER ubuntu

# Install mise
RUN curl https://mise.run | sh
ENV PATH="/home/ubuntu/.local/bin:${PATH}"

RUN mise settings set experimental true

WORKDIR /workspaces
