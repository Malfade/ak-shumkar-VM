#!/usr/bin/env bash

set -euo pipefail

COMPOSE_FILE="docker-compose.full.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Must match the project used at `docker compose up` / `start.sh`. Without this,
# Compose uses the directory name (e.g. ak-shumkar-vm) and `logs`/`ps` see no containers.
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-greenbone-community-edition}"
# Same as start.sh: patched gvmd image (composite scanner types 11/12).
USE_PATCHED_GVMD="${USE_PATCHED_GVMD:-1}"
COMPOSE_OVERRIDE_GVMD="${SCRIPT_DIR}/compose/gvmd-patched.override.yaml"

print_help() {
  cat <<'EOF'
Usage:
  ./scannerctl.sh deps       Install host build dependencies (apt: toolchain + OpenVAS libs)
  ./scannerctl.sh deploy     Build and deploy scanner stack (runs start.sh)
  ./scannerctl.sh disable    Stop and disable scanner stack
  ./scannerctl.sh status     Show scanner stack status
  ./scannerctl.sh logs       Tail scanner-related logs
  ./scannerctl.sh license    Manage customer-side license files (install/verify/status)
  ./scannerctl.sh license-vendor  Vendor-only licensing operations (gen-keys/issue/verify)
  ./scannerctl.sh harden     Restrict host access to one admin + one service account
  ./scannerctl.sh help       Show this help

deps:
  Installs Debian/Ubuntu packages from your repos. Does not run apt-get update
  (avoids touching package indexes on shared/production hosts; run it yourself if needed).
  Uses libcurl4-gnutls-dev and libssh-gcrypt-dev (same family as Greenbone images) —
  avoids removing those *-dev packages when replacing with OpenSSL variants.
  If apt has libgvm-base-dev (e.g. after adding Greenbone sources), installs them.
  Otherwise gvm-libs: build https://github.com/greenbone/gvm-libs or add GCE apt repo.
  Verify: pkg-config --exists libgvm_base libgvm_util libgvm_boreas && echo OK

deploy requires the full project directory, especially:
  Dockerfile.custom-openvas, Dockerfile.custom-ospd-openvas, docker-compose.full.yml
(start.sh copies those Dockerfiles into temp build contexts; replacing only shell scripts is not enough.)

OpenVAS C build: if host has no gvm-libs (pkg-config), start.sh builds in Docker using the same
  gvm-libs image as CI (registry.community.greenbone.net/community/gvm-libs:stable). Override:
  SCANNER_OPENVAS_BUILD_IN_DOCKER=1|0, SCANNER_OPENVAS_BUILD_IMAGE=...

If community registry pulls fail with "unexpected EOF", start.sh tries ghcr.io/greenbone for
  openvas-scanner and gvmd, retags locally, and skips docker build --pull. Disable mirror:
  SCANNER_SKIP_GHCR_PULL_FALLBACK=1

Patched gvmd (OpenVAS+CVE composite scanner): same as start.sh
  USE_PATCHED_GVMD=1 ./scannerctl.sh deploy

Force fresh image layers after fixing Dockerfiles:
  SCANNER_DOCKER_NO_CACHE=1 ./start.sh

Examples:
  ./scannerctl.sh deps
  ./scannerctl.sh deploy
  ./scannerctl.sh license status
  ./scannerctl.sh license-vendor --help
  sudo ./scannerctl.sh harden --admin-user <linux-user>
  ./scannerctl.sh disable
EOF
}

compose_cmd() {
  local compose_path="${SCRIPT_DIR}/${COMPOSE_FILE}"
  local compose_extra=()
  if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
    compose_extra+=(-f "${COMPOSE_OVERRIDE_GVMD}")
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${compose_path}" "${compose_extra[@]}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    local compat_compose
    compat_compose="$(mktemp)"
    awk '
      BEGIN { removed = 0 }
      !removed && $0 ~ /^name:[[:space:]]*/ { removed = 1; next }
      { print }
    ' "${compose_path}" > "${compat_compose}"
    local args=("$@")
    if [[ "${args[0]:-}" == "up" ]]; then
      local filtered=()
      local arg
      for arg in "${args[@]}"; do
        [[ "${arg}" == "--force-recreate" ]] && continue
        filtered+=("${arg}")
      done
      args=("${filtered[@]}")
    fi
    if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
      docker-compose -p "${COMPOSE_PROJECT_NAME}" --project-directory "${SCRIPT_DIR}" \
        -f "${compat_compose}" "${compose_extra[@]}" "${args[@]}"
    else
      docker-compose -p "${COMPOSE_PROJECT_NAME}" --project-directory "${SCRIPT_DIR}" \
        -f "${compat_compose}" "${args[@]}"
    fi
    local rc=$?
    rm -f "${compat_compose}"
    return "${rc}"
  else
    echo "❌ Docker Compose not found. Install Docker Compose (plugin or docker-compose binary)."
    exit 1
  fi
}

# Host packages for local OpenVAS C + CMake build (see misc/nasl CMakeLists.txt).
# gvm-libs must be installed separately (Greenbone repo or source build).
install_host_deps() {
  if [[ "$(id -u)" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo "❌ Need root or sudo to install packages."
    exit 1
  fi
  local run_as_root=()
  if [[ "$(id -u)" -ne 0 ]]; then
    run_as_root=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "📦 Installing build dependencies via apt-get..."
    echo "   (libcurl4-gnutls-dev + libssh-gcrypt-dev — совместимо со стеком Greenbone / Dockerfile.custom-*)"
    echo "   (apt-get update не вызывается — на серверах это может быть нежелательно; при необходимости обновите индекс вручную)"
    "${run_as_root[@]}" apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config ca-certificates git \
      libglib2.0-dev libjson-glib-dev \
      libgnutls28-dev libcurl4-gnutls-dev \
      libkrb5-dev \
      libpcap-dev libgpgme-dev libmagic-dev \
      libssh-gcrypt-dev libgcrypt20-dev libksba-dev libbsd-dev \
      libsnmp-dev \
      bison flex

    # If Greenbone / third-party apt sources are configured, pull in *.pc for gvm-libs.
    local gvm_candidates=(
      libgvm-base-dev
      libgvm-util-dev
      libgvm-boreas-dev
      libgvm22-dev
    )
    local gvm_install=()
    local p
    for p in "${gvm_candidates[@]}"; do
      if apt-cache show "${p}" >/dev/null 2>&1; then
        gvm_install+=("${p}")
      fi
    done
    if [[ "${#gvm_install[@]}" -gt 0 ]]; then
      echo "📦 Installing gvm-libs development packages from apt: ${gvm_install[*]}"
      "${run_as_root[@]}" apt-get install -y --no-install-recommends "${gvm_install[@]}"
    fi

    echo ""
    echo "✅ apt packages installed."
  elif command -v dnf >/dev/null 2>&1; then
    echo "📦 Installing build dependencies via dnf..."
    "${run_as_root[@]}" dnf install -y \
      gcc cmake pkgconfig git \
      glib2-devel json-glib-devel \
      gnutls-devel libcurl-devel \
      krb5-devel \
      libpcap-devel gpgme-devel file-devel \
      libssh-devel libgcrypt-devel libksba-devel libbsd-devel \
      net-snmp-devel \
      bison flex
    echo "✅ dnf packages installed."
  else
    echo "❌ No supported package manager found (need apt-get or dnf)."
    echo "   Install the equivalent *-devel packages for OpenVAS + CMake, then gvm-libs manually."
    exit 1
  fi

  echo ""
  echo "📌 Greenbone gvm-libs (required for ./start.sh host OpenVAS build):"
  echo "   Not provided by default Debian/Ubuntu repositories."
  echo "   • Add Greenbone Community Edition package sources for your distro, or"
  echo "   • Build and install: https://github.com/greenbone/gvm-libs"
  echo "   If installed under /usr/local, set: export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:\$PKG_CONFIG_PATH"
  echo "   Verify: pkg-config --exists libgvm_base libgvm_util libgvm_boreas && echo OK"
  echo ""
  echo "📌 Rust (openvasd): install rustup if cargo is missing:"
  echo "   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
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
  if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
    echo "   USE_PATCHED_GVMD=1 — compose will merge compose/gvmd-patched.override.yaml (same as start.sh)."
  fi
  cleanup_conflicting_soc_stack
  # Propagate USE_PATCHED_GVMD and COMPOSE_PROJECT_NAME to start.sh
  export COMPOSE_PROJECT_NAME
  export USE_PATCHED_GVMD
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

license_cmd() {
  local script="${SCRIPT_DIR}/security/licensectl.sh"
  if [[ ! -x "${script}" ]]; then
    echo "❌ ${script} is missing or not executable."
    exit 1
  fi
  "${script}" "$@"
}

license_vendor_cmd() {
  local script="${SCRIPT_DIR}/vendor/licensing/license-vendorctl.sh"
  if [[ ! -x "${script}" ]]; then
    echo "❌ ${script} is missing or not executable."
    echo "   Vendor tools are intentionally separated in vendor/licensing."
    exit 1
  fi
  "${script}" "$@"
}

harden_cmd() {
  local script="${SCRIPT_DIR}/security/enforce-single-account.sh"
  if [[ ! -x "${script}" ]]; then
    echo "❌ ${script} is missing or not executable."
    exit 1
  fi
  "${script}" "$@"
}

main() {
  local action="${1:-help}"
  shift || true
  case "${action}" in
    deps) install_host_deps ;;
    deploy) deploy_stack ;;
    disable) disable_stack ;;
    status) status_stack ;;
    logs) logs_stack ;;
    license) license_cmd "$@" ;;
    license-vendor) license_vendor_cmd "$@" ;;
    harden) harden_cmd "$@" ;;
    help|-h|--help) print_help ;;
    *)
      echo "❌ Unknown command: ${action}"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
