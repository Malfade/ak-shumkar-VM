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

# USE_PATCHED_GVMD=1 — build gvmd with OpenVAS+CVE composite scanners (types 11/12) from
# docker/gvmd-patched.Dockerfile and merge compose/gvmd-patched.override.yaml into compose.
# Requires third_party/gvmd (patched sources). Default: off (upstream community/gvmd image).
USE_PATCHED_GVMD="${USE_PATCHED_GVMD:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LICENSE_INSTALL_DIR="${LICENSE_INSTALL_DIR:-/etc/ak-shumkar/license}"
LICENSE_FILE="${LICENSE_FILE:-${LICENSE_INSTALL_DIR}/license.json}"
LICENSE_SIG_FILE="${LICENSE_SIG_FILE:-${LICENSE_INSTALL_DIR}/license.sig}"
LICENSE_PUBLIC_KEY="${LICENSE_PUBLIC_KEY:-${SCRIPT_DIR}/licenses/public.pem}"
ALLOW_EXPIRED_LICENSE="${ALLOW_EXPIRED_LICENSE:-0}"

COMPOSE_OVERRIDE_GVMD="${SCRIPT_DIR}/compose/gvmd-patched.override.yaml"

require_valid_license() {
  if [[ "${ALLOW_EXPIRED_LICENSE}" == "1" ]]; then
    echo "⚠️ ALLOW_EXPIRED_LICENSE=1 — license enforcement is bypassed for this run."
    return 0
  fi
  if [[ ! -f "${LICENSE_FILE}" || ! -f "${LICENSE_SIG_FILE}" ]]; then
    echo "❌ License is missing."
    echo "   Expected files:"
    echo "   - ${LICENSE_FILE}"
    echo "   - ${LICENSE_SIG_FILE}"
    echo "   Install using: ./security/licensectl.sh install --license-file <file> --signature-file <sig>"
    exit 1
  fi
  if [[ ! -f "${LICENSE_PUBLIC_KEY}" ]]; then
    echo "❌ Public key not found: ${LICENSE_PUBLIC_KEY}"
    echo "   Create or copy public key to this path (./security/licensectl.sh gen-keys)."
    exit 1
  fi
  if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "❌ openssl and python3 are required for license verification."
    exit 1
  fi

  local canonical
  canonical="$(mktemp)"
  python3 - "${LICENSE_FILE}" "${canonical}" <<'PY'
import json
import pathlib
import sys
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
obj = json.loads(src.read_text(encoding="utf-8"))
dst.write_text(json.dumps(obj, sort_keys=True, separators=(",", ":")), encoding="utf-8")
PY

  if ! openssl dgst -sha256 -verify "${LICENSE_PUBLIC_KEY}" -signature "${LICENSE_SIG_FILE}" "${canonical}" >/dev/null 2>&1; then
    rm -f "${canonical}"
    echo "❌ Invalid license signature."
    exit 1
  fi

  set +e
  python3 - "${canonical}" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
exp = datetime.strptime(data["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
if exp <= now:
    print(f"expired::{data.get('expires_at')}")
    sys.exit(2)
instance_id = (data.get("instance_id") or "").strip()
if instance_id:
    machine_id_path = pathlib.Path("/etc/machine-id")
    if machine_id_path.exists():
        current_machine_id = machine_id_path.read_text(encoding="utf-8").strip()
        if current_machine_id and current_machine_id != instance_id:
            print(f"instance_mismatch::{instance_id}::{current_machine_id}")
            sys.exit(3)
print(f"active::{data.get('expires_at')}")
PY
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    rm -f "${canonical}"
    if [[ "${rc}" -eq 2 ]]; then
      echo "❌ License expired. Scanner start is blocked."
    elif [[ "${rc}" -eq 3 ]]; then
      echo "❌ License instance binding mismatch (/etc/machine-id). Scanner start is blocked."
    else
      echo "❌ License validation failed."
    fi
    exit 1
  fi
  rm -f "${canonical}"
}

# Optional env: SCANNER_DOCKER_NO_PULL=1, SCANNER_SKIP_PRE_PULL=1, SCANNER_DOCKER_PULL_ATTEMPTS, SCANNER_DOCKER_BUILD_ATTEMPTS,
# SCANNER_DOCKER_NO_CACHE=1 — see pre_pull_custom_image_bases / docker_build_custom.
# SCANNER_SKIP_GHCR_PULL_FALLBACK=1 — do not use ghcr.io mirror when community registry fails (openvas-scanner, gvmd).
# After a successful GHCR mirror pull, custom docker builds skip --pull so a flaky community registry cannot invalidate the local tag.
# SCANNER_DOCKER_FORCE_BUILD_PULL=1 — force docker build --pull even when a mirror was used (may fail if community is down).
# SCANNER_CMAKE_EXTRA_ARGS — extra cmake flags (default: -DENABLE_CPACK=OFF). CPack during configure
# can fail with "Operation not permitted" in sandboxes or on some FS; omit CPack unless you package TGZ.
# Host OpenVAS C build needs Greenbone gvm-libs (pkg-config libgvm_base, libgvm_util, libgvm_boreas).
# If installed under a prefix: export PKG_CONFIG_PATH=/path/to/lib/pkgconfig
# SCANNER_OPENVAS_BUILD_IN_DOCKER — unset/auto: if host lacks gvm-libs but Docker works, run CMake in
#   registry.community.greenbone.net/community/gvm-libs:stable (same as CI). 1 = always docker C build.
#   0 = always host build (fails without pkg-config gvm-libs). Override image: SCANNER_OPENVAS_BUILD_IMAGE=...
docker_build_custom() {
  local tag="$1"
  local dockerfile="$2"
  local context="$3"
  local extra=()
  if [[ "${SCANNER_DOCKER_NO_PULL:-}" == "1" ]]; then
    echo "⏭️ SCANNER_DOCKER_NO_PULL=1 — building without --pull (use local base cache)"
  elif [[ "${SCANNER_USED_GHCR_MIRROR:-0}" == "1" ]] && [[ "${SCANNER_DOCKER_FORCE_BUILD_PULL:-}" != "1" ]]; then
    echo "⏭️ Bases loaded via GHCR mirror — docker build without --pull (community registry was flaky)."
  else
    extra+=(--pull)
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
  local compose_extra=()
  if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
    compose_extra+=(-f "${COMPOSE_OVERRIDE_GVMD}")
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${compose_path}" "${compose_extra[@]}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    # docker-compose v1 does not understand top-level `name:` in compose spec.
    # Strip only that key for compatibility while keeping service definitions intact.
    local compat_compose
    compat_compose="$(mktemp)"
    awk '
      BEGIN { removed = 0 }
      !removed && $0 ~ /^name:[[:space:]]*/ { removed = 1; next }
      { print }
    ' "${compose_path}" > "${compat_compose}"
    # docker-compose v1 is fragile with `up --force-recreate` on modern images
    # and may crash with KeyError: 'ContainerConfig'.
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
      docker-compose -p "${COMPOSE_PROJECT_NAME}" --project-directory "${SCRIPT_DIR}" -f "${compat_compose}" "${args[@]}"
    fi
    local rc=$?
    rm -f "${compat_compose}"
    return "${rc}"
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

version_ge() {
  # Returns 0 when $1 >= $2 according to semantic version sort.
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

choose_cargo_cmd() {
  local required="1.85.0"

  if command -v cargo >/dev/null 2>&1; then
    local cargo_ver
    cargo_ver="$(cargo --version 2>/dev/null | awk '{print $2}')"
    if [[ -n "${cargo_ver}" ]] && version_ge "${cargo_ver}" "${required}"; then
      echo "cargo"
      return 0
    fi
  fi

  if command -v rustup >/dev/null 2>&1; then
    echo "rustup run stable cargo"
    return 0
  fi

  return 1
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
      echo "   OpenVAS scanner / gvmd: community pull tries GHCR mirror + retag unless SCANNER_SKIP_GHCR_PULL_FALLBACK=1."
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

# Pull from community registry; on each failure optionally pull the same image from GHCR and retag
# so Dockerfiles that use community refs keep working. Sets SCANNER_USED_GHCR_MIRROR=1 when mirror wins.
retry_docker_pull_community_with_ghcr_fallback() {
  local community_ref="$1"
  local ghcr_mirror="${2:-}"
  local attempts="${SCANNER_DOCKER_PULL_ATTEMPTS:-20}"
  local n=1
  while true; do
    if docker pull "${community_ref}"; then
      return 0
    fi
    if [[ -n "${ghcr_mirror}" ]] && [[ "${SCANNER_SKIP_GHCR_PULL_FALLBACK:-}" != "1" ]]; then
      echo "⚠️ Community registry failed for ${community_ref}; trying mirror ${ghcr_mirror} ..."
      if docker pull "${ghcr_mirror}"; then
        docker tag "${ghcr_mirror}" "${community_ref}"
        SCANNER_USED_GHCR_MIRROR=1
        echo "✅ Mirror OK — tagged as ${community_ref} (custom builds skip docker --pull)."
        return 0
      fi
    fi
    if [[ "$n" -ge "$attempts" ]]; then
      echo "❌ docker pull gave up after ${attempts} attempts: ${community_ref}"
      echo "   \"unexpected EOF\" is usually the registry or network dropping the connection mid-layer."
      if [[ -n "${ghcr_mirror}" ]] && [[ "${SCANNER_SKIP_GHCR_PULL_FALLBACK:-}" == "1" ]]; then
        echo "   GHCR mirror was skipped (SCANNER_SKIP_GHCR_PULL_FALLBACK=1). Unset it to try ${ghcr_mirror}."
      elif [[ -z "${ghcr_mirror}" ]]; then
        echo "   No public GHCR mirror is wired for this image; try VPN or pull from another network."
      fi
      echo "   Mitigations: stable network/VPN; max-concurrent-downloads:1 in Docker daemon.json."
      echo "   Pre-seed: pull on another machine, docker save/load, then SCANNER_SKIP_PRE_PULL=1 SCANNER_DOCKER_NO_PULL=1 ./start.sh"
      return 1
    fi
    local sleep_s=$((10 + (n - 1) * 10))
    [[ "$sleep_s" -gt 180 ]] && sleep_s=180
    echo "⚠️ Pull attempt ${n}/${attempts} failed for ${community_ref}, retrying in ${sleep_s}s..."
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
    case "${image}" in
      registry.community.greenbone.net/community/openvas-scanner:stable)
        retry_docker_pull_community_with_ghcr_fallback "${image}" ghcr.io/greenbone/openvas-scanner:stable
        ;;
      registry.community.greenbone.net/community/gvmd:stable)
        retry_docker_pull_community_with_ghcr_fallback "${image}" ghcr.io/greenbone/gvmd:stable
        ;;
      *)
        retry_cmd 5 docker pull "${image}"
        ;;
    esac
  done <<< "${images}"
}

# Prime layer cache before docker build --pull; Greenbone registry pulls often flake mid-layer.
pre_pull_custom_image_bases() {
  if [[ "${SCANNER_SKIP_PRE_PULL:-}" == "1" ]]; then
    echo "⏭️ SCANNER_SKIP_PRE_PULL=1 — skipping explicit docker pull of custom build bases"
    return 0
  fi
  SCANNER_USED_GHCR_MIRROR=0
  echo "📥 Pre-pulling base images for custom Docker builds (retries, SCANNER_DOCKER_PULL_ATTEMPTS=${SCANNER_DOCKER_PULL_ATTEMPTS:-20})..."
  echo "   Flaky community registry: openvas-scanner / gvmd fall back to ghcr.io/greenbone/* (unless SCANNER_SKIP_GHCR_PULL_FALLBACK=1)."
  retry_docker_pull_community_with_ghcr_fallback \
    registry.community.greenbone.net/community/openvas-scanner:stable \
    ghcr.io/greenbone/openvas-scanner:stable
  retry_docker_pull registry.community.greenbone.net/community/ospd-openvas:stable
  retry_docker_pull debian:bookworm-slim
  if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
    echo "📥 Pre-pulling gvmd patched build bases..."
    retry_docker_pull ghcr.io/greenbone/gvm-libs:stable
    retry_docker_pull_community_with_ghcr_fallback \
      registry.community.greenbone.net/community/gvmd:stable \
      ghcr.io/greenbone/gvmd:stable
  fi
}

verify_scanner_dockerfiles

require_valid_license

# OpenVAS C build on the host links against Greenbone gvm-libs (pkg-config: libgvm_base, …).
# Stock Ubuntu/Debian often ship without these; install from Greenbone CE repo or build gvm-libs from source.
require_host_gvm_libs() {
  if pkg-config --exists libgvm_base libgvm_util libgvm_boreas 2>/dev/null; then
    return 0
  fi
  echo "❌ На хосте не найдены gvm-libs для сборки OpenVAS (pkg-config: libgvm_base, libgvm_util, libgvm_boreas)."
  echo "   Проверка: pkg-config --exists libgvm_base libgvm_util libgvm_boreas && echo OK  → должно напечатать OK."
  echo ""
  echo "   Варианты:"
  echo "   1) Поставить dev-пакеты из стека Greenbone GCE для вашего дистрибутива (см. документацию установки менеджера/сканера)."
  echo "   2) Собрать и установить https://github.com/greenbone/gvm-libs , затем при необходимости:"
  echo "        export PKG_CONFIG_PATH=\"/usr/local/lib/pkgconfig:\${PKG_CONFIG_PATH}\""
  echo "   3) Если библиотеки уже в нестандартном префиксе — задайте PKG_CONFIG_PATH на каталог с *.pc."
  echo "   4) Сборка OpenVAS в контейнере (без gvm-libs на хосте): Docker должен быть доступен; по умолчанию"
  echo "      ./start.sh сам использует образ gvm-libs, если на хосте нет pkg-config. Явно:"
  echo "        SCANNER_OPENVAS_BUILD_IN_DOCKER=1 ./start.sh"
  echo "      Только на хосте (без авто-Docker): SCANNER_OPENVAS_BUILD_IN_DOCKER=0 ./start.sh"
  exit 1
}

host_has_gvm_libs_pkgconfig() {
  pkg-config --exists libgvm_base libgvm_util libgvm_boreas 2>/dev/null
}

# After Docker C build, build/ is often root-owned; plain rm on the host may fail.
force_rm_build_dir() {
  [[ -d build ]] || return 0
  if rm -rf build 2>/dev/null; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "⚠️ Удаляю build/ через контейнер (каталог создан root при сборке в Docker)..."
    docker run --rm -v "${SCRIPT_DIR}:/src:rw" alpine:3.20 rm -rf /src/build
    return 0
  fi
  echo "❌ Не удалось удалить build/ (нет прав). Выполните: sudo rm -rf \"${SCRIPT_DIR}/build\""
  exit 1
}

use_openvas_docker_c_build() {
  if [[ "${SCANNER_OPENVAS_BUILD_IN_DOCKER:-}" == "1" ]]; then
    return 0
  fi
  if [[ "${SCANNER_OPENVAS_BUILD_IN_DOCKER:-}" == "0" ]]; then
    return 1
  fi
  if host_has_gvm_libs_pkgconfig; then
    return 1
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

reset_build_dir_if_foreign_cache() {
  [[ -f "build/CMakeCache.txt" ]] || return 0
  # Docker C build uses source mount at /src; host uses SCRIPT_DIR — caches are not interchangeable.
  if grep -q '^CMAKE_HOME_DIRECTORY:INTERNAL=/src$' build/CMakeCache.txt 2>/dev/null; then
    echo "⚠️ CMake cache from in-container build (/src). Reconfiguring build/ for host..."
    force_rm_build_dir
    return 0
  fi
  if ! awk -v p="$SCRIPT_DIR" '
  /^CMAKE_HOME_DIRECTORY:INTERNAL=/ {
    if (index($0, p) > 0) ok=1
  }
  END { exit ok ? 0 : 1 }
' build/CMakeCache.txt; then
    echo "⚠️ Detected foreign CMake cache path. Reconfiguring build directory..."
    rm -f build/CMakeCache.txt
    rm -rf build/CMakeFiles
  fi
}

reset_build_dir_before_docker_cmake() {
  [[ -f "build/CMakeCache.txt" ]] || return 0
  if grep -q '^CMAKE_HOME_DIRECTORY:INTERNAL=/src$' build/CMakeCache.txt 2>/dev/null; then
    return 0
  fi
  echo "⚠️ CMake cache не от Docker-сборки (/src). Пересоздаю build/ для сборки в контейнере..."
  force_rm_build_dir
}

build_openvas_c_on_host() {
  require_host_gvm_libs
  reset_build_dir_if_foreign_cache
  echo "🛠️ Configuring CMake project (host)..."
  : "${SCANNER_CMAKE_EXTRA_ARGS:=-DENABLE_CPACK=OFF}"
  retry_cmd 3 cmake -S . -B build ${SCANNER_CMAKE_EXTRA_ARGS}
  cmake --build "build" -j"$(nproc)"
}

build_openvas_c_in_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker не установлен — нужен для сборки OpenVAS C в контейнере."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon недоступен (запустите docker и проверьте доступ к сокету)."
    exit 1
  fi
  local img="${SCANNER_OPENVAS_BUILD_IMAGE:-registry.community.greenbone.net/community/gvm-libs:stable}"
  if [[ "${SCANNER_DOCKER_NO_PULL:-}" != "1" ]]; then
    echo "📥 Pulling OpenVAS C build image (${img})..."
    retry_docker_pull "${img}"
  else
    echo "⏭️ SCANNER_DOCKER_NO_PULL=1 — using local cache for ${img}"
  fi

  echo "🛠️ Configuring & building CMake project in Docker (${img})..."
  : "${SCANNER_CMAKE_EXTRA_ARGS:=-DENABLE_CPACK=OFF}"
  reset_build_dir_before_docker_cmake
  # install-openvas-dependencies.sh and cmake run as root in container; build/ may be root-owned on host.
  docker run --rm \
    -v "${SCRIPT_DIR}:/src:rw" \
    -w /src \
    -e "SCANNER_CMAKE_EXTRA_ARGS=${SCANNER_CMAKE_EXTRA_ARGS}" \
    "${img}" \
    bash -lc 'set -euo pipefail
      sh .github/install-openvas-dependencies.sh
      # Mounted repo is owned by host UID; git 2.35+ refuses it unless marked safe.
      git config --global --add safe.directory /src
      cmake -S . -B build ${SCANNER_CMAKE_EXTRA_ARGS}
      cmake --build build -j"$(nproc)"'
}

if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
  if [[ ! -f "${SCRIPT_DIR}/docker/gvmd-patched.Dockerfile" ]]; then
    echo "❌ USE_PATCHED_GVMD=1 but docker/gvmd-patched.Dockerfile is missing."
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/third_party/gvmd/CMakeLists.txt" ]]; then
    echo "ℹ️ third_party/gvmd is missing, bootstrapping patched gvmd sources..."
    if ! command -v git >/dev/null 2>&1; then
      echo "❌ git is required to auto-bootstrap third_party/gvmd."
      exit 1
    fi
    retry_cmd 3 git clone --depth 1 https://github.com/greenbone/gvmd.git "${SCRIPT_DIR}/third_party/gvmd"
  fi
  if [[ ! -f "${SCRIPT_DIR}/third_party/gvmd/CMakeLists.txt" ]]; then
    echo "❌ Auto-bootstrap failed: ${SCRIPT_DIR}/third_party/gvmd/CMakeLists.txt not found."
    exit 1
  fi
  GVMD_PATCH="${SCRIPT_DIR}/patches/gvmd-composite-scanner.patch"
  if [[ -f "${GVMD_PATCH}" ]]; then
    if git -C "${SCRIPT_DIR}/third_party/gvmd" apply --check "${GVMD_PATCH}" >/dev/null 2>&1; then
      echo "🩹 Applying patches/gvmd-composite-scanner.patch to third_party/gvmd..."
      git -C "${SCRIPT_DIR}/third_party/gvmd" apply "${GVMD_PATCH}"
    else
      echo "ℹ️ gvmd composite patch already applied or not cleanly applicable; continuing."
    fi
  fi
  echo "🧩 USE_PATCHED_GVMD=1 — will build gvmd from docker/gvmd-patched.Dockerfile (types 11/12)."
fi

echo "🐍 Building openvasd (Rust backend)..."
if CARGO_CMD="$(choose_cargo_cmd)"; then
  (
    cd rust
    ${CARGO_CMD} build --release --bin openvasd --features nasl-builtin-raw-ip
  )
else
  echo "❌ Rust toolchain is too old for edition 2024 and rustup is not available."
  echo "   Install rustup and run: rustup toolchain install stable"
  echo "   Then rerun ./start.sh"
  if [[ ! -f "rust/target/release/openvasd" ]]; then
    echo "❌ rust/target/release/openvasd is missing. Install Rust toolchain on the server or build openvasd elsewhere."
    exit 1
  fi
fi

echo "🧱 Building OpenVAS C artifacts..."
if use_openvas_docker_c_build; then
  if [[ "${SCANNER_OPENVAS_BUILD_IN_DOCKER:-}" != "1" ]] && ! host_has_gvm_libs_pkgconfig; then
    echo "ℹ️ На хосте нет gvm-libs (pkg-config); собираю OpenVAS C внутри Docker (образ gvm-libs, как в CI)."
    echo "   Только хост: установите gvm-libs или SCANNER_OPENVAS_BUILD_IN_DOCKER=0 для явной ошибки без Docker."
  fi
  build_openvas_c_in_docker
else
  build_openvas_c_on_host
fi

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

if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
  echo "🐳 Building patched gvmd image (ak-shumkar-gvmd:local)..."
  docker_build_custom ak-shumkar-gvmd:local "${SCRIPT_DIR}/docker/gvmd-patched.Dockerfile" "${SCRIPT_DIR}"
fi

echo "🚀 Starting Greenbone Community Edition Stack..."

# Vite build references /config.js from index.html. Ensure it exists in gsa root.
if [[ ! -f "${SCRIPT_DIR}/gsa/config.js" ]]; then
  if [[ -f "${SCRIPT_DIR}/gsa/public/config.js" ]]; then
    echo "ℹ️ gsa/config.js missing — copying from gsa/public/config.js"
    cp "${SCRIPT_DIR}/gsa/public/config.js" "${SCRIPT_DIR}/gsa/config.js"
  else
    echo "ℹ️ gsa/config.js and gsa/public/config.js missing — creating default config.js"
    cat > "${SCRIPT_DIR}/gsa/config.js" <<'EOF'
window.GSA_CONFIG = {
  apiServer: window.location.host,
  apiProtocol: window.location.protocol.slice(0, -1),
};
EOF
  fi
fi

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
if [[ "${USE_PATCHED_GVMD}" == "1" ]]; then
  echo "🧩 gvmd: patched image (OpenVAS + CVE composite scanner types 11/12)."
fi
