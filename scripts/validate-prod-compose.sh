#!/usr/bin/env bash
# Validate production compose using example env values only.

set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/infra" "$TMP_DIR/env"
cp "$ROOT/docker-compose.prod.yml" "$TMP_DIR/infra/docker-compose.prod.yml"
cp "$ROOT/env/.env.prod.example" "$TMP_DIR/.env"
mkdir -p "$TMP_DIR/env"
cp "$ROOT/env/backend.prod.env.example" "$TMP_DIR/env/backend.prod.env"
cp "$ROOT/env/eats.prod.env.example" "$TMP_DIR/env/eats.prod.env"
cp "$ROOT/env/business.prod.env.example" "$TMP_DIR/env/business.prod.env"
cp "$ROOT/env/adminpanel.prod.env.example" "$TMP_DIR/env/adminpanel.prod.env"

docker compose -f "$TMP_DIR/infra/docker-compose.prod.yml" --env-file "$TMP_DIR/.env" config >/dev/null
echo "production compose config ok"
