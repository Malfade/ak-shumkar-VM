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
  # OpenVAS C and GSA frontend are built inside Docker containers (gvm-libs:stable, node:22-alpine).
  # Keep host packages minimal to avoid apt conflicts with existing OpenSSL/libcurl stacks.
  # If building OpenVAS C directly on the host (SCANNER_OPENVAS_BUILD_IN_DOCKER=0), run: ./scannerctl.sh deps
  log "Installing minimal host packages..."
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    cmake \
    build-essential \
    pkg-config \
    libssl-dev \
    openssl \
    python3 \
    rsync
}

ensure_docker_stack() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker binary already exists, skipping docker package install."
  else
    log "Installing Docker engine packages..."
    sudo apt-get install -y docker.io
  fi

  if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
    log "Docker Compose is already available."
  else
    log "Installing Docker Compose..."
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
      sudo apt-get install -y docker-compose-plugin
    elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      sudo apt-get install -y docker-compose-v2
    else
      sudo apt-get install -y docker-compose
    fi
  fi
}

ensure_docker_service() {
  log "Ensuring Docker service is enabled and running..."
  sudo systemctl enable docker.service >/dev/null 2>&1 || true
  sudo systemctl start docker.service
}

ensure_docker_group_access() {
  local target_user="${SUDO_USER:-$USER}"
  if id -nG "${target_user}" | tr ' ' '\n' | awk '$0=="docker"{found=1} END{exit found?0:1}'; then
    log "User '${target_user}' is already in docker group."
  else
    log "Adding user '${target_user}' to docker group..."
    sudo usermod -aG docker "${target_user}"
    log "User group updated. Re-login may be required."
  fi
}

install_rust_if_missing() {
  if [[ -f "${HOME}/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.cargo/env"
  fi
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
  echo "  3) Ensure the full scanner tree is present (not only start.sh):"
  echo "       Dockerfile.custom-openvas, Dockerfile.custom-ospd-openvas, docker-compose.full.yml, …"
  echo "  4) ./scannerctl.sh deploy"
  echo "  5) If ospd still fails after an old tarball deploy: SCANNER_DOCKER_NO_CACHE=1 ./start.sh"
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
