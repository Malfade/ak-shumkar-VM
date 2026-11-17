#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

OUTPUT_DIR_DEFAULT="${SCRIPT_DIR}/output"
REPO_PUBLIC_KEY="${REPO_ROOT}/licenses/public.pem"

usage() {
  cat <<'EOF'
Usage:
  ./vendor/licensing/license-vendorctl.sh gen-keys [--out-dir DIR] [--bits 4096] [--force] [--no-sync-public]
  ./vendor/licensing/license-vendorctl.sh issue --customer-id ID --months N [--instance-id ID] [--out-dir DIR] [--private-key FILE] [--public-key FILE]
  ./vendor/licensing/license-vendorctl.sh verify --license-file FILE --signature-file FILE [--public-key FILE]

Vendor-only operations:
  - Keep vendor/licensing/output/private.pem strictly off production/customer hosts.
  - Only distribute licenses/public.pem, license-*.json, and license-*.json.sig.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "❌ Missing required command: ${cmd}"
    exit 1
  fi
}

validate_customer_id() {
  local cid="$1"
  if [[ ! "${cid}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "❌ Invalid --customer-id '${cid}'. Allowed characters: a-z, A-Z, 0-9, '.', '_', '-'."
    exit 1
  fi
}

canonicalize_json() {
  local src="$1"
  local dst="$2"
  python3 - "${src}" "${dst}" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
obj = json.loads(src.read_text(encoding="utf-8"))
dst.write_text(json.dumps(obj, sort_keys=True, separators=(",", ":")), encoding="utf-8")
PY
}

cmd_gen_keys() {
  require_cmd openssl
  local out_dir="${OUTPUT_DIR_DEFAULT}"
  local bits="4096"
  local force="0"
  local sync_public="1"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir) out_dir="${2:-}"; shift 2 ;;
      --bits) bits="${2:-}"; shift 2 ;;
      --force) force="1"; shift ;;
      --no-sync-public) sync_public="0"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ ! "${bits}" =~ ^[0-9]+$ ]] || [[ "${bits}" -lt 2048 ]]; then
    echo "❌ Invalid RSA key size '${bits}'. Must be >= 2048 (recommended: 4096)."
    exit 1
  fi

  mkdir -p "${out_dir}"
  local priv_key="${out_dir}/private.pem"
  local pub_key="${out_dir}/public.pem"

  if [[ -f "${priv_key}" && "${force}" != "1" ]]; then
    echo "❌ Private key already exists: ${priv_key}"
    echo "   Refusing to overwrite existing vendor master key. Pass --force to replace it."
    exit 1
  fi

  (
    umask 077
    openssl genrsa -out "${priv_key}" "${bits}" >/dev/null 2>&1
  )
  chmod 600 "${priv_key}"

  openssl rsa -in "${priv_key}" -pubout -out "${pub_key}" >/dev/null 2>&1
  chmod 644 "${pub_key}"

  echo "✅ Generated RSA-${bits} vendor keypair:"
  echo "   Private key (SECRET): ${priv_key}"
  echo "   Public key          : ${pub_key}"

  if [[ "${sync_public}" == "1" ]]; then
    mkdir -p "$(dirname "${REPO_PUBLIC_KEY}")"
    cp "${pub_key}" "${REPO_PUBLIC_KEY}"
    chmod 644 "${REPO_PUBLIC_KEY}"
    echo "✅ Synced public key to: ${REPO_PUBLIC_KEY}"
  fi
}

cmd_issue() {
  require_cmd openssl
  require_cmd python3

  local customer_id=""
  local months=""
  local instance_id=""
  local out_dir="${OUTPUT_DIR_DEFAULT}"
  local priv_key="${OUTPUT_DIR_DEFAULT}/private.pem"
  local pub_key="${OUTPUT_DIR_DEFAULT}/public.pem"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --customer-id) customer_id="${2:-}"; shift 2 ;;
      --months) months="${2:-}"; shift 2 ;;
      --instance-id) instance_id="${2:-}"; shift 2 ;;
      --out-dir) out_dir="${2:-}"; shift 2 ;;
      --private-key) priv_key="${2:-}"; shift 2 ;;
      --public-key) pub_key="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  : "${customer_id:?--customer-id is required}"
  : "${months:?--months is required}"

  validate_customer_id "${customer_id}"
  if [[ ! "${months}" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ Invalid --months '${months}'. Must be a positive integer (e.g. 3, 6, 12)."
    exit 1
  fi

  if [[ ! -f "${priv_key}" ]]; then
    echo "❌ Vendor private key not found: ${priv_key}"
    echo "   Run './scannerctl.sh license-vendor gen-keys' first."
    exit 1
  fi

  mkdir -p "${out_dir}"
  local license_file="${out_dir}/license-${customer_id}-${months}m.json"
  local sig_file="${license_file}.sig"

  python3 - "${license_file}" "${customer_id}" "${months}" "${instance_id}" <<'PY'
import json
import pathlib
import sys
import uuid
from datetime import datetime, timedelta, timezone

out_path = pathlib.Path(sys.argv[1])
customer_id = sys.argv[2]
months = int(sys.argv[3])
instance_id = sys.argv[4].strip()

now = datetime.now(timezone.utc).replace(microsecond=0)
exp = now + timedelta(days=30 * months)

payload = {
    "customer_id": customer_id,
    "expires_at": exp.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "issued_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "license_id": str(uuid.uuid4()),
    "plan_months": months,
    "product": "ak-shumkar-vm",
    "schema_version": 1,
}
if instance_id:
    payload["instance_id"] = instance_id

out_path.write_text(
    json.dumps(payload, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY

  openssl dgst -sha256 -sign "${priv_key}" -out "${sig_file}" "${license_file}"
  chmod 644 "${license_file}" "${sig_file}"

  # Verify signature immediately if public key is available
  local verify_pub="${pub_key}"
  if [[ ! -f "${verify_pub}" && -f "${REPO_PUBLIC_KEY}" ]]; then
    verify_pub="${REPO_PUBLIC_KEY}"
  fi
  if [[ -f "${verify_pub}" ]]; then
    if ! openssl dgst -sha256 -verify "${verify_pub}" -signature "${sig_file}" "${license_file}" >/dev/null 2>&1; then
      echo "❌ Self-verification failed against ${verify_pub} (keypair mismatch)."
      exit 1
    fi
  fi

  echo "✅ Issued license:"
  echo "   License file  : ${license_file}"
  echo "   Signature file: ${sig_file}"
  cat "${license_file}"
  echo
}

cmd_verify() {
  require_cmd openssl
  require_cmd python3

  local license_file=""
  local signature_file=""
  local public_key="${REPO_PUBLIC_KEY}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --license-file) license_file="${2:-}"; shift 2 ;;
      --signature-file) signature_file="${2:-}"; shift 2 ;;
      --public-key) public_key="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  : "${license_file:?--license-file is required}"
  : "${signature_file:?--signature-file is required}"

  if [[ ! -f "${public_key}" ]]; then
    if [[ -f "${OUTPUT_DIR_DEFAULT}/public.pem" ]]; then
      public_key="${OUTPUT_DIR_DEFAULT}/public.pem"
    else
      echo "❌ Public key not found: ${public_key}"
      exit 1
    fi
  fi

  local canonical
  canonical="$(mktemp)"
  canonicalize_json "${license_file}" "${canonical}"
  if ! openssl dgst -sha256 -verify "${public_key}" -signature "${signature_file}" "${canonical}" >/dev/null 2>&1; then
    rm -f "${canonical}"
    echo "❌ Signature is invalid."
    exit 1
  fi
  rm -f "${canonical}"
  echo "✅ Signature is valid (public key: ${public_key})."
}

main() {
  local action="${1:-help}"
  shift || true
  case "${action}" in
    gen-keys) cmd_gen_keys "$@" ;;
    issue) cmd_issue "$@" ;;
    verify) cmd_verify "$@" ;;
    help|-h|--help) usage ;;
    *)
      echo "❌ Unknown action: ${action}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
