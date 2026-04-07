#!/usr/bin/env bash

set -euo pipefail

COMPOSE_FILE="docker-compose.full.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Must match the project used at `docker compose up` / `start.sh`. Without this,
# Compose uses the directory name (e.g. ak-shumkar-vm) and `logs`/`ps` see no containers.
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-greenbone-community-edition}"

print_help() {
  cat <<'EOF'
Usage:
  ./scannerctl.sh deploy     Build and deploy scanner stack (runs start.sh)
  ./scannerctl.sh disable    Stop and disable scanner stack
  ./scannerctl.sh status     Show scanner stack status
  ./scannerctl.sh logs       Tail scanner-related logs
  ./scannerctl.sh help       Show this help

deploy requires the full project directory, especially:
  Dockerfile.custom-openvas, Dockerfile.custom-ospd-openvas, docker-compose.full.yml
(start.sh copies those Dockerfiles into temp build contexts; replacing only shell scripts is not enough.)

Force fresh image layers after fixing Dockerfiles:
  SCANNER_DOCKER_NO_CACHE=1 ./start.sh

Examples:
  ./scannerctl.sh deploy
  ./scannerctl.sh disable
EOF
}

compose_cmd() {
  local compose_path="${SCRIPT_DIR}/${COMPOSE_FILE}"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${compose_path}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -p "${COMPOSE_PROJECT_NAME}" -f "${compose_path}" "$@"
  else
    echo "❌ Docker Compose not found. Install Docker Compose (plugin or docker-compose binary)."
    exit 1
  fi
}

cleanup_conflicting_soc_stack() {
  require_docker
  local removed_any=0

  for name in soc-elasticsearch soc-kibana soc-filebeat soc-elastalert; do
    if docker ps -a --format '{{.Names}}' | awk -v n="$name" '$0==n {found=1} END{exit found?0:1}'; then
      echo "🧹 Removing conflicting container: ${name}"
      docker rm -f "${name}" >/dev/null
      removed_any=1
    fi
  done

  if docker network ls --format '{{.Name}}' | awk '$0=="elasticsearch-soc_soc-net" {found=1} END{exit found?0:1}'; then
    echo "🧹 Removing conflicting network: elasticsearch-soc_soc-net"
    docker network rm elasticsearch-soc_soc-net >/dev/null || true
    removed_any=1
  fi

  if [[ "${removed_any}" -eq 1 ]]; then
    echo "✅ Conflicting SOC stack cleaned."
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed."
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    cat <<'EOF'
❌ Docker daemon is not reachable.
Start Docker and/or grant access to /var/run/docker.sock.

Typical fixes:
  sudo systemctl start docker
  sudo usermod -aG docker "$USER"   # then re-login
EOF
    exit 1
  fi
}

deploy_stack() {
  require_docker
  if [[ ! -f "${SCRIPT_DIR}/start.sh" ]]; then
    echo "❌ start.sh not found in ${SCRIPT_DIR}"
    exit 1
  fi

  echo "🚀 Deploying scanner stack..."
  cleanup_conflicting_soc_stack
  "${SCRIPT_DIR}/start.sh"
}

disable_stack() {
  require_docker
  echo "🛑 Disabling scanner stack..."
  compose_cmd down --remove-orphans
  cleanup_conflicting_soc_stack
  echo "✅ Scanner stack is disabled."
}

status_stack() {
  require_docker
  compose_cmd ps
}

logs_stack() {
  require_docker
  echo "📜 Project: ${COMPOSE_PROJECT_NAME} (override with COMPOSE_PROJECT_NAME=...)"
  compose_cmd logs -f --tail=100 openvasd openvas ospd-openvas gvmd gsad gsa
}

main() {
  local action="${1:-help}"
  case "${action}" in
    deploy) deploy_stack ;;
    disable) disable_stack ;;
    status) status_stack ;;
    logs) logs_stack ;;
    help|-h|--help) print_help ;;
    *)
      echo "❌ Unknown command: ${action}"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
