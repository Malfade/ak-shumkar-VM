#!/bin/bash

# SPDX-FileCopyrightText: 2024 Greenbone AG
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e

# --- Configuration ---
COMPOSE_FILE="docker-compose.full.yml"
GSA_DIR="./gsa"
PSQL_SOCKET_VOL="greenbone-community-edition_psql_socket_vol"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
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

pre_pull_images() {
  echo "📥 Pre-pulling compose images with retries..."
  local images
  images="$(compose_cmd -f "$COMPOSE_FILE" config --images | awk 'NF')"
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

echo "🐳 Rebuilding openvasd-custom Docker image..."
# Use a temporary build context to avoid .dockerignore excluding `rust/target`.
TMP_BUILD_DIR="$(mktemp -d)"
cp "Dockerfile.custom-openvasd" "${TMP_BUILD_DIR}/Dockerfile.custom-openvasd"
mkdir -p "${TMP_BUILD_DIR}/rust/target/release"
cp "rust/target/release/openvasd" "${TMP_BUILD_DIR}/rust/target/release/openvasd"
cp "udp_scanner.nasl" "${TMP_BUILD_DIR}/udp_scanner.nasl"
retry_cmd 5 docker build -f "${TMP_BUILD_DIR}/Dockerfile.custom-openvasd" -t openvasd-custom:latest "${TMP_BUILD_DIR}"
rm -rf "${TMP_BUILD_DIR}"

echo "🐳 Rebuilding openvas-custom Docker image..."
# Use a temporary build context to avoid .dockerignore excluding `build/`.
TMP_BUILD_DIR_OPENVAS="$(mktemp -d)"
cp "Dockerfile.custom-openvas" "${TMP_BUILD_DIR_OPENVAS}/Dockerfile.custom-openvas"
mkdir -p "${TMP_BUILD_DIR_OPENVAS}/build/src" "${TMP_BUILD_DIR_OPENVAS}/build/nasl" "${TMP_BUILD_DIR_OPENVAS}/build/misc"
cp "build/src/openvas" "${TMP_BUILD_DIR_OPENVAS}/build/src/openvas"
cp "build/nasl/libopenvas_nasl.so" "${TMP_BUILD_DIR_OPENVAS}/build/nasl/libopenvas_nasl.so"
cp "build/misc/libopenvas_misc.so" "${TMP_BUILD_DIR_OPENVAS}/build/misc/libopenvas_misc.so"
retry_cmd 5 docker build -f "${TMP_BUILD_DIR_OPENVAS}/Dockerfile.custom-openvas" -t openvas-custom:latest "${TMP_BUILD_DIR_OPENVAS}"
rm -rf "${TMP_BUILD_DIR_OPENVAS}"

echo "🐳 Rebuilding ospd-openvas-custom Docker image..."
TMP_BUILD_DIR_OSPD="$(mktemp -d)"
cp "Dockerfile.custom-ospd-openvas" "${TMP_BUILD_DIR_OSPD}/Dockerfile.custom-ospd-openvas"
mkdir -p "${TMP_BUILD_DIR_OSPD}/build/src" "${TMP_BUILD_DIR_OSPD}/build/nasl" "${TMP_BUILD_DIR_OSPD}/build/misc"
cp "build/src/openvas" "${TMP_BUILD_DIR_OSPD}/build/src/openvas"
cp "build/nasl/libopenvas_nasl.so" "${TMP_BUILD_DIR_OSPD}/build/nasl/libopenvas_nasl.so"
cp "build/misc/libopenvas_misc.so" "${TMP_BUILD_DIR_OSPD}/build/misc/libopenvas_misc.so"
retry_cmd 5 docker build -f "${TMP_BUILD_DIR_OSPD}/Dockerfile.custom-ospd-openvas" -t ospd-openvas-custom:latest "${TMP_BUILD_DIR_OSPD}"
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
retry_cmd 3 compose_cmd -f "$COMPOSE_FILE" down --remove-orphans

# 3. Cleanup Postgres Lock Files right before startup
echo "🧹 Cleaning up Postgres lock files..."
retry_cmd 3 docker run --rm -v "${PSQL_SOCKET_VOL}:/socket" alpine rm -f /socket/.s.PGSQL.5432.lock /socket/.s.PGSQL.5432

# 4. Startup Stack and force recreation to apply custom images/config
echo "🐳 Starting Docker containers..."
pre_pull_images
retry_cmd 3 compose_cmd -f "$COMPOSE_FILE" up -d --remove-orphans --force-recreate

echo "✅ Stack is up and running!"
echo "📍 Access GSA at: http://localhost:9393"
