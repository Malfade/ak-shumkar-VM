#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SERVICE_USER="${SERVICE_USER:-scanner}"
SERVICE_GROUP="${SERVICE_GROUP:-scanner}"
ADMIN_USER="${ADMIN_USER:-}"
PROJECT_DIR="${PROJECT_DIR:-${REPO_ROOT}}"

usage() {
  cat <<'EOF'
Usage:
  sudo ./security/enforce-single-account.sh --admin-user <linux-user> [--service-user scanner] [--project-dir PATH]

What it does:
  - Ensures one admin account is explicitly allowed in sshd via AllowUsers.
  - Creates/ensures dedicated service user/group for scanner runtime.
  - Restricts project directory permissions to service user + admin group.

Notes:
  - Root keeps full access by Linux design.
  - Script updates /etc/ssh/sshd_config and restarts ssh/sshd service.
EOF
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ Run this script as root (sudo)."
    exit 1
  fi
}

ensure_user_group() {
  if ! getent group "${SERVICE_GROUP}" >/dev/null; then
    groupadd --system "${SERVICE_GROUP}"
  fi
  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${SERVICE_GROUP}" --shell /usr/sbin/nologin --create-home "${SERVICE_USER}"
  fi
}

configure_sshd_allow_user() {
  local cfg="/etc/ssh/sshd_config"
  if [[ ! -f "${cfg}" ]]; then
    echo "⚠️ ${cfg} not found; skipping ssh hardening."
    return 0
  fi
  cp "${cfg}" "${cfg}.bak.$(date +%s)"
  sed -i '/^AllowUsers[[:space:]]\+/d' "${cfg}"
  {
    echo ""
    echo "# Managed by enforce-single-account.sh"
    echo "AllowUsers ${ADMIN_USER}"
    echo "PermitRootLogin no"
    echo "PasswordAuthentication no"
  } >> "${cfg}"

  if systemctl is-active --quiet ssh; then
    systemctl restart ssh
  elif systemctl is-active --quiet sshd; then
    systemctl restart sshd
  fi
}

restrict_project_permissions() {
  local admin_group
  admin_group="$(id -gn "${ADMIN_USER}")"

  usermod -aG "${SERVICE_GROUP}" "${ADMIN_USER}"
  chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PROJECT_DIR}"
  chmod -R o-rwx "${PROJECT_DIR}"
  find "${PROJECT_DIR}" -type d -exec chmod 750 {} +
  find "${PROJECT_DIR}" -type f -exec chmod 640 {} +

  # Keep scripts executable for service/admin workflows.
  chmod 750 "${PROJECT_DIR}/start.sh" "${PROJECT_DIR}/scannerctl.sh" || true
  if [[ -d "${PROJECT_DIR}/security" ]]; then
    find "${PROJECT_DIR}/security" -maxdepth 1 -type f -name "*.sh" -exec chmod 750 {} +
  fi

  # Allow admin primary group to read/execute without opening for others.
  chgrp -R "${admin_group}" "${PROJECT_DIR}"
  chmod -R g+rX "${PROJECT_DIR}"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
      --service-user) SERVICE_USER="${2:-}"; SERVICE_GROUP="${2:-}"; shift 2 ;;
      --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -z "${ADMIN_USER}" ]]; then
    echo "❌ --admin-user is required."
    exit 1
  fi
  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    echo "❌ Admin user does not exist: ${ADMIN_USER}"
    exit 1
  fi

  require_root
  ensure_user_group
  configure_sshd_allow_user
  restrict_project_permissions

  echo "✅ Hardening applied."
  echo "   Admin account   : ${ADMIN_USER}"
  echo "   Service account : ${SERVICE_USER}"
  echo "   Project dir     : ${PROJECT_DIR}"
}

main "$@"
