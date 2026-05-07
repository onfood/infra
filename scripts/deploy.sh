#!/usr/bin/env bash
# deploy.sh — pull latest images, run migrations, restart stack.
#
# Called by:
#   - GitHub Actions workflows (after pushing new image to GHCR)
#   - Manually for ad-hoc redeploys
#
# Single-arg mode: deploy.sh <service>
#   only that service is pulled + restarted (used by per-app CI jobs).
# No-arg mode: pulls all images, restarts everything.
#
# Always runs migrations job before bringing services up.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/qber}
COMPOSE="docker compose -f $INSTALL_DIR/infra/docker-compose.yml --env-file $INSTALL_DIR/.env"

SERVICE=${1:-}

log() { echo -e "\033[1;32m[deploy]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

cd "$INSTALL_DIR"

# Login to GHCR (token comes from /opt/qber/.ghcr-token, written by bootstrap)
if [[ -f $INSTALL_DIR/.ghcr-token ]]; then
  log "ghcr login"
  cat $INSTALL_DIR/.ghcr-token | docker login ghcr.io -u $(cat $INSTALL_DIR/.ghcr-user) --password-stdin >/dev/null
fi

# Pull
if [[ -n "$SERVICE" ]]; then
  log "pulling $SERVICE"
  $COMPOSE pull "$SERVICE"
else
  log "pulling all services"
  $COMPOSE pull
fi

# Always run migrations (one-shot, exits when done)
# Skip if SERVICE is "migrate" itself (avoid loop) or if a single non-backend service is targeted.
case "$SERVICE" in
  ""|customer-api|business-api|admin-api|migrate)
    log "running migrations"
    $COMPOSE run --rm migrate
    ;;
  *)
    log "skipping migrations for frontend-only deploy of $SERVICE"
    ;;
esac

# Bring services up (zero-downtime where possible)
if [[ -n "$SERVICE" && "$SERVICE" != "migrate" ]]; then
  log "restarting $SERVICE"
  $COMPOSE up -d --no-deps --remove-orphans "$SERVICE"
elif [[ -z "$SERVICE" ]]; then
  log "starting full stack"
  $COMPOSE up -d --remove-orphans
fi

# Healthcheck
sleep 5
log "container status"
$COMPOSE ps

# Cleanup unused images
log "pruning old images"
docker image prune -af --filter "until=168h" >/dev/null

log "deploy complete"
