#!/usr/bin/env bash
set -euo pipefail

# Install helper for scanner distribution ISO.
# Installs project files to /opt/ak-shumkar-VM and optionally starts stack.

INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/ak-shumkar-VM}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ak-shumkar-VM"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "Source directory not found: ${SOURCE_DIR}"
  echo "Run this script from mounted ISO root."
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

echo "Installing project to ${INSTALL_PREFIX} ..."
mkdir -p "${INSTALL_PREFIX}"
rsync -a --delete "${SOURCE_DIR}/" "${INSTALL_PREFIX}/"
chmod +x "${INSTALL_PREFIX}"/*.sh "${INSTALL_PREFIX}"/security/*.sh 2>/dev/null || true

cat <<EOF
Installation complete.

Next steps:
1) cd ${INSTALL_PREFIX}
2) (If clean host) Install Docker & system deps:
   sudo ./bootstrap_server.sh
3) Install customer license files:
   sudo ./scannerctl.sh license install --license-file <license.json> --signature-file <license.sig>
4) Deploy scanner stack:
   ./scannerctl.sh deploy
   # Or for pilot/testing without a license: ALLOW_EXPIRED_LICENSE=1 ./scannerctl.sh deploy
EOF
