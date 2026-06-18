#!/usr/bin/env bash
# backup.sh — nightly pg_dump of the onfood-dev database.
# Runs from cron as the deploy user. Keeps last 14 dumps, gzipped.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-dev}
BACKUP_DIR=$INSTALL_DIR/backups
KEEP_DAYS=14

mkdir -p "$BACKUP_DIR"

# Source top-level env for POSTGRES_USER/PASSWORD/DB
set -a
source "$INSTALL_DIR/.env"
set +a

ts=$(date -u +%Y-%m-%dT%H-%M-%S)
out="$BACKUP_DIR/onfood-dev-$ts.sql.gz"

# pg_dump runs inside compose so we don't need network exposure
docker compose -f "$INSTALL_DIR/infra/docker-compose.yml" --env-file "$INSTALL_DIR/.env" \
  exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl \
  | gzip > "$out"

echo "wrote $out ($(du -h "$out" | cut -f1))"

# Prune old
find "$BACKUP_DIR" -name "onfood-dev-*.sql.gz" -type f -mtime +$KEEP_DAYS -delete -print
