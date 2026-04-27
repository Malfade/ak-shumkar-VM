#!/usr/bin/env bash
set -euo pipefail

# Build a distributable ISO containing the scanner source tree and install helper.
# This ISO is data-only (non-bootable) and intended for product delivery.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="${1:-$(date +%Y.%m.%d)}"
ISO_LABEL="${ISO_LABEL:-AK_SHUMKAR_VM_${VERSION//./_}}"
OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/dist}"
STAGING_DIR="${OUT_DIR}/iso-staging"
ISO_NAME="ak-shumkar-vm-${VERSION}.iso"
ISO_PATH="${OUT_DIR}/${ISO_NAME}"

mkdir -p "${OUT_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/ak-shumkar-VM"

echo "Preparing staging directory..."
rsync -a \
  --delete \
  --exclude '.git' \
  --exclude '.github' \
  --exclude '.idea' \
  --exclude '.vscode' \
  --exclude 'build' \
  --exclude 'dist' \
  --exclude 'target' \
  --exclude '*.iso' \
  "${PROJECT_ROOT}/" "${STAGING_DIR}/ak-shumkar-VM/"

cp "${SCRIPT_DIR}/install-from-iso.sh" "${STAGING_DIR}/install.sh"
chmod +x "${STAGING_DIR}/install.sh"

cat > "${STAGING_DIR}/README.txt" <<EOF
AK SHUMKAR VM Scanner Distribution
==================================

Contents:
- ak-shumkar-VM/      scanner project tree
- install.sh          helper installer script for Linux hosts

Quick start:
1) Mount ISO:
   sudo mount -o loop ${ISO_NAME} /mnt
2) Run installer:
   sudo bash /mnt/install.sh

Legal:
- This package contains components under GPL/AGPL and other OSS licenses.
- See ak-shumkar-VM/COPYING and ak-shumkar-VM/license-details.md.
EOF

if command -v xorriso >/dev/null 2>&1; then
  echo "Creating ISO with xorriso..."
  xorriso -as mkisofs \
    -iso-level 3 \
    -J -R \
    -V "${ISO_LABEL:0:32}" \
    -o "${ISO_PATH}" \
    "${STAGING_DIR}"
elif command -v genisoimage >/dev/null 2>&1; then
  echo "Creating ISO with genisoimage..."
  genisoimage \
    -iso-level 3 \
    -J -R \
    -V "${ISO_LABEL:0:32}" \
    -o "${ISO_PATH}" \
    "${STAGING_DIR}"
elif command -v mkisofs >/dev/null 2>&1; then
  echo "Creating ISO with mkisofs..."
  mkisofs \
    -iso-level 3 \
    -J -R \
    -V "${ISO_LABEL:0:32}" \
    -o "${ISO_PATH}" \
    "${STAGING_DIR}"
else
  echo "No ISO builder found. Install one of: xorriso, genisoimage, mkisofs."
  exit 1
fi

(cd "${OUT_DIR}" && sha256sum "${ISO_NAME}" > "${ISO_NAME}.sha256")
rm -rf "${STAGING_DIR}"

echo "ISO created: ${ISO_PATH}"
echo "Checksum:    ${ISO_PATH}.sha256"
