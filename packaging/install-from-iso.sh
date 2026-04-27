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

cat <<EOF
Installation complete.

Next steps:
1) cd ${INSTALL_PREFIX}
2) Ensure license files are installed:
   ./security/licensectl.sh install --license-file <license.json> --signature-file <license.sig>
3) Start scanner stack:
   ./start.sh
EOF
