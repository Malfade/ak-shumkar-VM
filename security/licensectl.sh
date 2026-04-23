#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LICENSE_DIR_DEFAULT="${REPO_ROOT}/licenses"
LICENSE_INSTALL_DIR_DEFAULT="/etc/ak-shumkar/license"
PUBLIC_KEY_DEFAULT="${LICENSE_DIR_DEFAULT}/public.pem"

usage() {
  cat <<'EOF'
Usage:
  ./security/licensectl.sh verify --license-file FILE --signature-file FILE --public-key FILE
  ./security/licensectl.sh install --license-file FILE --signature-file FILE [--install-dir DIR]
  ./security/licensectl.sh status [--install-dir DIR] [--public-key FILE]

Customer mode only:
  - This script does NOT create keys and does NOT issue licenses.
  - Vendor operations are intentionally moved to vendor/licensing/license-vendorctl.sh.

Notes:
  - License is JSON + detached OpenSSL signature.
  - Runtime checks are done by ./start.sh.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "❌ Missing required command: ${cmd}"
    exit 1
  fi
}

canonicalize_json() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
obj = json.loads(src.read_text(encoding="utf-8"))
dst.write_text(json.dumps(obj, sort_keys=True, separators=(",", ":")), encoding="utf-8")
PY
}

cmd_verify() {
  require_cmd openssl
  local license_file=""
  local signature_file=""
  local public_key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --license-file) license_file="${2:-}"; shift 2 ;;
      --signature-file) signature_file="${2:-}"; shift 2 ;;
      --public-key) public_key="${2:-}"; shift 2 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  : "${license_file:?--license-file is required}"
  : "${signature_file:?--signature-file is required}"
  : "${public_key:?--public-key is required}"

  local canonical
  canonical="$(mktemp)"
  canonicalize_json "${license_file}" "${canonical}"
  if openssl dgst -sha256 -verify "${public_key}" -signature "${signature_file}" "${canonical}" >/dev/null 2>&1; then
    echo "✅ Signature is valid."
  else
    echo "❌ Signature is invalid."
    rm -f "${canonical}"
    exit 1
  fi
  rm -f "${canonical}"
}

cmd_install() {
  local license_file=""
  local signature_file=""
  local install_dir="${LICENSE_INSTALL_DIR_DEFAULT}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --license-file) license_file="${2:-}"; shift 2 ;;
      --signature-file) signature_file="${2:-}"; shift 2 ;;
      --install-dir) install_dir="${2:-}"; shift 2 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done
  : "${license_file:?--license-file is required}"
  : "${signature_file:?--signature-file is required}"

  local run_as_root=()
  if [[ "$(id -u)" -ne 0 ]]; then
    require_cmd sudo
    run_as_root=(sudo)
  fi

  "${run_as_root[@]}" mkdir -p "${install_dir}"
  "${run_as_root[@]}" cp "${license_file}" "${install_dir}/license.json"
  "${run_as_root[@]}" cp "${signature_file}" "${install_dir}/license.sig"
  "${run_as_root[@]}" chown -R root:root "${install_dir}"
  "${run_as_root[@]}" chmod 755 "${install_dir}"
  "${run_as_root[@]}" chmod 644 "${install_dir}/license.json" "${install_dir}/license.sig"
  echo "✅ Installed license into ${install_dir}"
}

cmd_status() {
  require_cmd python3
  require_cmd openssl
  local install_dir="${LICENSE_INSTALL_DIR_DEFAULT}"
  local public_key="${PUBLIC_KEY_DEFAULT}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="${2:-}"; shift 2 ;;
      --public-key) public_key="${2:-}"; shift 2 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  local license_file="${install_dir}/license.json"
  local signature_file="${install_dir}/license.sig"
  if [[ ! -f "${license_file}" || ! -f "${signature_file}" ]]; then
    echo "❌ No installed license at ${install_dir}"
    exit 1
  fi
  if [[ ! -f "${public_key}" ]]; then
    echo "❌ Public key not found: ${public_key}"
    exit 1
  fi

  if ! "${BASH_SOURCE[0]}" verify --license-file "${license_file}" --signature-file "${signature_file}" --public-key "${public_key}" >/dev/null; then
    echo "❌ Installed license signature invalid."
    exit 1
  fi

  python3 - "${license_file}" <<'PY'
import json
import sys
from datetime import datetime, timezone

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
exp = datetime.strptime(data["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
remaining = int((exp - now).total_seconds() // 86400)
print(f"license_id  : {data.get('license_id')}")
print(f"customer_id : {data.get('customer_id')}")
print(f"plan_months : {data.get('plan_months')}")
print(f"issued_at   : {data.get('issued_at')}")
print(f"expires_at  : {data.get('expires_at')}")
print(f"instance_id : {data.get('instance_id')}")
print(f"status      : {'expired' if exp <= now else 'active'} ({remaining} days left)")
PY
}

main() {
  local action="${1:-help}"
  shift || true
  case "${action}" in
    verify) cmd_verify "$@" ;;
    install) cmd_install "$@" ;;
    status) cmd_status "$@" ;;
    help|-h|--help) usage ;;
    *) echo "❌ Unknown action: ${action}"; usage; exit 1 ;;
  esac
}

main "$@"
