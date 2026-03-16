#!/bin/bash

# SPDX-FileCopyrightText: 2024 Greenbone AG
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e

# --- Configuration ---
COMPOSE_FILE="docker-compose.full.yml"
GSA_DIR="./gsa"
PSQL_SOCKET_VOL="greenbone-community-edition_psql_socket_vol"

echo "🚀 Starting Greenbone Community Edition Stack..."

# 1. Build Frontend
echo "📦 Building GSA Frontend inside Docker (Node 22)..."
docker run --rm \
  -v "$(pwd)/gsa:/app" \
  -w /app \
  node:22-alpine \
  sh -c "npm install && npm run build"

# 2. Cleanup Postgres Lock Files
echo "🧹 Cleaning up Postgres lock files..."
docker run --rm -v "${PSQL_SOCKET_VOL}:/socket" alpine rm -f /socket/.s.PGSQL.5432.lock /socket/.s.PGSQL.5432

# 3. Startup Stack
echo "🐳 Starting Docker containers..."
docker-compose -f "$COMPOSE_FILE" down
docker-compose -f "$COMPOSE_FILE" up -d

echo "✅ Stack is up and running!"
echo "📍 Access GSA at: http://localhost:9393"
