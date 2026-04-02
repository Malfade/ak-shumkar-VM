#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  echo "[bootstrap] $*"
}

require_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required but not installed."
    exit 1
  fi
}

install_base_packages() {
  log "Installing base system packages..."
  sudo apt update
  sudo apt install -y \
    ca-certificates \
    curl \
    git \
    cmake \
    build-essential \
    pkg-config \
    libssl-dev \
    libmagic-dev \
    libkrb5-dev
}

ensure_docker_stack() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker binary already exists, skipping docker package install."
  else
    log "Installing Docker engine packages..."
    sudo apt install -y docker.io
  fi

  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin is already available."
  else
    log "Installing Docker Compose plugin..."
    sudo apt install -y docker-compose-plugin
  fi
}

ensure_docker_service() {
  log "Ensuring Docker service is enabled and running..."
  sudo systemctl enable docker.service >/dev/null 2>&1 || true
  sudo systemctl start docker.service
}

ensure_docker_group_access() {
  if id -nG "$USER" | tr ' ' '\n' | awk '$0=="docker"{found=1} END{exit found?0:1}'; then
    log "User '$USER' is already in docker group."
  else
    log "Adding user '$USER' to docker group..."
    sudo usermod -aG docker "$USER"
    log "User group updated. Re-login may be required."
  fi
}

install_rust_if_missing() {
  if command -v cargo >/dev/null 2>&1; then
    log "Rust is already installed."
    return
  fi

  log "Installing Rust toolchain..."
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
}

verify_tools() {
  log "Verifying required tools..."
  command -v docker >/dev/null 2>&1
  command -v cmake >/dev/null 2>&1
  command -v cargo >/dev/null 2>&1
}

show_next_steps() {
  echo
  log "Bootstrap completed."
  echo "Project path: ${SCRIPT_DIR}"
  echo "Docker root: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo 'docker access requires re-login')"
  echo
  echo "Next steps:"
  echo "  1) If docker commands fail, re-login or run: newgrp docker"
  echo "  2) cd \"${SCRIPT_DIR}\""
  echo "  3) ./scannerctl.sh deploy"
}

main() {
  require_sudo
  install_base_packages
  ensure_docker_stack
  ensure_docker_service
  ensure_docker_group_access
  install_rust_if_missing
  verify_tools
  show_next_steps
}

main "$@"
