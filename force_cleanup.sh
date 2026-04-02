#!/bin/bash
# force_cleanup_v2.sh
# Aggressive cleanup of stuck Docker containers and shims.

echo "🛑 Stopping Snap Docker..."
sudo snap stop docker

echo "🔪 Kill-All stuck container shims..."
sudo pkill -9 containerd-shim
sudo pkill -9 containerd-shim-runc-v2

echo "🔪 Kill-All remaining Greenbone processes..."
# More generic process killing
sudo pkill -9 -f "openvas"
sudo pkill -9 -f "gvmd"
sudo pkill -9 -f "gsad"
sudo pkill -9 -f "gsa"
sudo pkill -9 -f "openvasd"
sudo pkill -9 -f "ospd-openvas"
sudo pkill -9 -f "notus-scanner"

echo "🧹 Cleaning up AppArmor profiles (expect some I/O errors, it is okay)..."
sudo aa-remove-unknown || true

echo "🚀 Restarting Snap Docker..."
# Try to start services individually to pinpoint failure
sudo snap start docker.dockerd
sudo snap start docker

echo "🗑️ Removing stale containers..."
docker rm -f $(docker ps -aq --filter "name=greenbone") 2>/dev/null || true

echo "✅ Cleanup complete. Check if 'docker ps' works now."
