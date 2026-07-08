#!/usr/bin/env bash
# Nightly pg_dump of the onfood-prod database. Keeps last 14 dumps.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-prod}
BACKUP_DIR=$INSTALL_DIR/backups
KEEP_DAYS=${KEEP_DAYS:-14}
COMPOSE_FILE=$INSTALL_DIR/infra/docker-compose.prod.yml
ENV_FILE=$INSTALL_DIR/.env

mkdir -p "$BACKUP_DIR"

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

ts=$(date -u +%Y-%m-%dT%H-%M-%S)
out="$BACKUP_DIR/onfood-prod-$ts.sql.gz"

docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
  exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl \
  | gzip > "$out"

echo "wrote $out ($(du -h "$out" | cut -f1))"

find "$BACKUP_DIR" -name "onfood-prod-*.sql.gz" -type f -mtime +"$KEEP_DAYS" -delete -print
