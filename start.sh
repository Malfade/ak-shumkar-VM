#!/bin/bash

# SPDX-FileCopyrightText: 2024 Greenbone AG
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e

# --- Configuration ---
COMPOSE_FILE="docker-compose.full.yml"
# Match scannerctl.sh / manual `docker compose -p ...` so volumes and container names stay consistent.
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-greenbone-community-edition}"
GSA_DIR="./gsa"
PSQL_SOCKET_VOL="${COMPOSE_PROJECT_NAME}_psql_socket_vol"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Optional env: SCANNER_DOCKER_NO_PULL=1, SCANNER_SKIP_PRE_PULL=1, SCANNER_DOCKER_PULL_ATTEMPTS, SCANNER_DOCKER_BUILD_ATTEMPTS,
# SCANNER_DOCKER_NO_CACHE=1 — see pre_pull_custom_image_bases / docker_build_custom.
docker_build_custom() {
  local tag="$1"
  local dockerfile="$2"
  local context="$3"
  local extra=()
  if [[ "${SCANNER_DOCKER_NO_PULL:-}" != "1" ]]; then
    extra+=(--pull)
  else
    echo "⏭️ SCANNER_DOCKER_NO_PULL=1 — building without --pull (use local base cache)"
  fi
  if [[ "${SCANNER_DOCKER_NO_CACHE:-}" == "1" ]]; then
    extra+=(--no-cache)
    echo "🔄 SCANNER_DOCKER_NO_CACHE=1 — building without cache"
  fi
  retry_cmd "${SCANNER_DOCKER_BUILD_ATTEMPTS:-10}" docker build "${extra[@]}" -f "${dockerfile}" -t "${tag}" "${context}"
}

# start.sh only copies Dockerfiles from this repo — replacing start.sh alone does not fix runtime libs.
verify_scanner_dockerfiles() {
  local f
  for f in Dockerfile.custom-openvas Dockerfile.custom-ospd-openvas; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
      echo "❌ Missing ${f} in ${SCRIPT_DIR}"
      echo "   Deploy needs the full tree (especially Dockerfile.custom-*), not only start.sh."
      exit 1
    fi
    if ! grep -q 'bookworm-slim' "${SCRIPT_DIR}/${f}" || ! grep -q 'libssh-gcrypt' "${SCRIPT_DIR}/${f}"; then
      echo "❌ ${f} looks outdated: expected multi-stage copy of libssh-gcrypt from debian:bookworm-slim."
      echo "   Greenbone ospd/openvas images are Debian Trixie — there is no libssh-gcrypt-4 package there."
      echo "   Copy the current Dockerfile.custom-openvas and Dockerfile.custom-ospd-openvas from the project repo."
      exit 1
    fi
  done
}

compose_cmd() {
  local compose_path="${SCRIPT_DIR}/${COMPOSE_FILE}"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${compose_path}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -p "${COMPOSE_PROJECT_NAME}" -f "${compose_path}" "$@"
  else
    echo "❌ Docker Compose not found."
    exit 1
  fi
}

retry_cmd() {
  local attempts="${1:-5}"
  shift
  local n=1
  until "$@"; do
    if [[ "$n" -ge "$attempts" ]]; then
      echo "❌ Command failed after ${attempts} attempts: $*"
      return 1
    fi
    local sleep_s=$((n * 5))
    echo "⚠️ Attempt ${n}/${attempts} failed, retrying in ${sleep_s}s: $*"
    sleep "${sleep_s}"
    n=$((n + 1))
  done
}

# Large images + flaky paths often fail with "unexpected EOF"; use slower backoff and more tries than retry_cmd.
retry_docker_pull() {
  local image="$1"
  local attempts="${SCANNER_DOCKER_PULL_ATTEMPTS:-20}"
  local n=1
  while true; do
    if docker pull "${image}"; then
      return 0
    fi
    if [[ "$n" -ge "$attempts" ]]; then
      echo "❌ docker pull gave up after ${attempts} attempts: ${image}"
      echo "   \"unexpected EOF\" is usually the registry or network dropping the connection mid-layer."
      echo "   Mitigations: stable network/VPN; retry later; pull on another host and docker save/load."
      echo "   Docker daemon: set \"max-concurrent-downloads\": 1 in /etc/docker/daemon.json, then restart docker."
      echo "   This script: SCANNER_SKIP_PRE_PULL=1 SCANNER_DOCKER_NO_PULL=1 ./start.sh (needs images already local)."
      return 1
    fi
    local sleep_s=$((10 + (n - 1) * 10))
    [[ "$sleep_s" -gt 180 ]] && sleep_s=180
    echo "⚠️ Pull attempt ${n}/${attempts} failed for ${image}, retrying in ${sleep_s}s..."
    sleep "${sleep_s}"
    n=$((n + 1))
  done
}

pre_pull_images() {
  echo "📥 Pre-pulling compose images with retries..."
  local images
  images="$(compose_cmd config --images | awk 'NF')"
  if [[ -z "${images}" ]]; then
    echo "⚠️ No compose images discovered, skipping pre-pull."
    return 0
  fi

  while IFS= read -r image; do
    [[ -z "${image}" ]] && continue
    # Local custom images are built in this script and should not be pulled.
    if [[ "${image}" != */* ]]; then
      echo "⏭️ Skipping pull for local image: ${image}"
      continue
    fi
    retry_cmd 5 docker pull "${image}"
  done <<< "${images}"
}

# Prime layer cache before docker build --pull; Greenbone registry pulls often flake mid-layer.
pre_pull_custom_image_bases() {
  if [[ "${SCANNER_SKIP_PRE_PULL:-}" == "1" ]]; then
    echo "⏭️ SCANNER_SKIP_PRE_PULL=1 — skipping explicit docker pull of custom build bases"
    return 0
  fi
  echo "📥 Pre-pulling base images for custom Docker builds (retries, SCANNER_DOCKER_PULL_ATTEMPTS=${SCANNER_DOCKER_PULL_ATTEMPTS:-20})..."
  retry_docker_pull registry.community.greenbone.net/community/openvas-scanner:stable
  retry_docker_pull registry.community.greenbone.net/community/ospd-openvas:stable
  retry_docker_pull debian:bookworm-slim
}

verify_scanner_dockerfiles

echo "🐍 Building openvasd (Rust backend)..."
if command -v cargo >/dev/null 2>&1; then
  (
    cd rust
    cargo build --release --bin openvasd --features nasl-builtin-raw-ip
  )
else
  echo "⚠️ cargo not found. Skipping Rust build."
  if [[ ! -f "rust/target/release/openvasd" ]]; then
    echo "❌ rust/target/release/openvasd is missing. Install Rust toolchain on the server or build openvasd elsewhere."
    exit 1
  fi
fi

echo "🧱 Building OpenVAS C artifacts..."
if [[ -f "build/CMakeCache.txt" ]] && ! awk -v p="$SCRIPT_DIR" '
  /^CMAKE_HOME_DIRECTORY:INTERNAL=/ {
    if (index($0, p) > 0) ok=1
  }
  END { exit ok ? 0 : 1 }
' build/CMakeCache.txt; then
  echo "⚠️ Detected foreign CMake cache path. Reconfiguring build directory..."
  rm -f build/CMakeCache.txt
  rm -rf build/CMakeFiles
fi

echo "🛠️ Configuring CMake project..."
retry_cmd 3 cmake -S . -B build

cmake --build "build" -j"$(nproc)"

pre_pull_custom_image_bases

echo "🐳 Rebuilding openvasd-custom Docker image..."
# Use a temporary build context to avoid .dockerignore excluding `rust/target`.
TMP_BUILD_DIR="$(mktemp -d)"
cp "Dockerfile.custom-openvasd" "${TMP_BUILD_DIR}/Dockerfile.custom-openvasd"
mkdir -p "${TMP_BUILD_DIR}/rust/target/release"
cp "rust/target/release/openvasd" "${TMP_BUILD_DIR}/rust/target/release/openvasd"
cp "udp_scanner.nasl" "${TMP_BUILD_DIR}/udp_scanner.nasl"
docker_build_custom openvasd-custom:latest "${TMP_BUILD_DIR}/Dockerfile.custom-openvasd" "${TMP_BUILD_DIR}"
rm -rf "${TMP_BUILD_DIR}"

echo "🐳 Rebuilding openvas-custom Docker image..."
# Use a temporary build context to avoid .dockerignore excluding `build/`.
TMP_BUILD_DIR_OPENVAS="$(mktemp -d)"
cp "Dockerfile.custom-openvas" "${TMP_BUILD_DIR_OPENVAS}/Dockerfile.custom-openvas"
mkdir -p "${TMP_BUILD_DIR_OPENVAS}/build/src" "${TMP_BUILD_DIR_OPENVAS}/build/nasl" "${TMP_BUILD_DIR_OPENVAS}/build/misc"
cp "build/src/openvas" "${TMP_BUILD_DIR_OPENVAS}/build/src/openvas"
cp "build/nasl/libopenvas_nasl.so" "${TMP_BUILD_DIR_OPENVAS}/build/nasl/libopenvas_nasl.so"
cp "build/misc/libopenvas_misc.so" "${TMP_BUILD_DIR_OPENVAS}/build/misc/libopenvas_misc.so"
docker_build_custom openvas-custom:latest "${TMP_BUILD_DIR_OPENVAS}/Dockerfile.custom-openvas" "${TMP_BUILD_DIR_OPENVAS}"
rm -rf "${TMP_BUILD_DIR_OPENVAS}"

echo "🐳 Rebuilding ospd-openvas-custom Docker image..."
TMP_BUILD_DIR_OSPD="$(mktemp -d)"
cp "Dockerfile.custom-ospd-openvas" "${TMP_BUILD_DIR_OSPD}/Dockerfile.custom-ospd-openvas"
mkdir -p "${TMP_BUILD_DIR_OSPD}/build/src" "${TMP_BUILD_DIR_OSPD}/build/nasl" "${TMP_BUILD_DIR_OSPD}/build/misc"
cp "build/src/openvas" "${TMP_BUILD_DIR_OSPD}/build/src/openvas"
cp "build/nasl/libopenvas_nasl.so" "${TMP_BUILD_DIR_OSPD}/build/nasl/libopenvas_nasl.so"
cp "build/misc/libopenvas_misc.so" "${TMP_BUILD_DIR_OSPD}/build/misc/libopenvas_misc.so"
docker_build_custom ospd-openvas-custom:latest "${TMP_BUILD_DIR_OSPD}/Dockerfile.custom-ospd-openvas" "${TMP_BUILD_DIR_OSPD}"
rm -rf "${TMP_BUILD_DIR_OSPD}"

echo "🚀 Starting Greenbone Community Edition Stack..."

# 1. Build Frontend
echo "📦 Building GSA Frontend inside Docker (Node 22)..."
retry_cmd 3 docker run --rm \
  -v "$(pwd)/gsa:/app" \
  -w /app \
  node:22-alpine \
  sh -c "npm install && npm run build"

# 2. Stop existing stack first (if any)
echo "🐳 Stopping existing Docker containers..."
retry_cmd 3 compose_cmd down --remove-orphans

# 3. Cleanup Postgres Lock Files right before startup
echo "🧹 Cleaning up Postgres lock files..."
retry_cmd 3 docker run --rm -v "${PSQL_SOCKET_VOL}:/socket" alpine rm -f /socket/.s.PGSQL.5432.lock /socket/.s.PGSQL.5432

# 4. Startup Stack and force recreation to apply custom images/config
echo "🐳 Starting Docker containers..."
pre_pull_images
retry_cmd 3 compose_cmd up -d --remove-orphans --force-recreate

echo "✅ Stack is up and running!"
echo "📍 Access GSA at: http://localhost:9393"
