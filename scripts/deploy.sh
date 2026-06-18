#!/usr/bin/env bash
# deploy.sh — pull latest images, run migrations, (re)start the onfood-dev stack.
#
# Called by each app repo's GitHub Actions workflow over SSH after a new image
# is pushed to GHCR, and usable manually for ad-hoc redeploys.
#
#   deploy.sh                # full stack: pull all, migrate, up everything
#   deploy.sh backend        # pull+restart the 5 Go services (runs migrate first)
#   deploy.sh migrations     # run the one-shot migrate job only
#   deploy.sh eats           # pull+restart the eats frontend only
#   deploy.sh business       # pull+restart the business frontend only
#   deploy.sh adminpanel     # pull+restart the adminpanel only

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-dev}
COMPOSE="docker compose -f $INSTALL_DIR/infra/docker-compose.yml --env-file $INSTALL_DIR/.env"

SERVICE=${1:-}

log() { echo -e "\033[1;32m[deploy]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

cd "$INSTALL_DIR"

# Map the deploy identifier to compose service(s) + whether to run migrations.
RUN_MIGRATE=0
ONLY_MIGRATE=0
case "$SERVICE" in
  "")            TARGETS=""; RUN_MIGRATE=1 ;;
  backend)       TARGETS="eats-api business-api eats-bot business-bot scheduler"; RUN_MIGRATE=1 ;;
  migrations|migrate) TARGETS=""; RUN_MIGRATE=1; ONLY_MIGRATE=1 ;;
  eats|business|adminpanel) TARGETS="$SERVICE" ;;
  *)             TARGETS="$SERVICE" ;;
esac

# GHCR login (token + user written during setup). Skipped if absent — works
# without it when the onfood dev packages are public.
if [[ -f $INSTALL_DIR/.ghcr-token && -f $INSTALL_DIR/.ghcr-user ]]; then
  log "ghcr login"
  cat "$INSTALL_DIR/.ghcr-token" | docker login ghcr.io \
    -u "$(cat "$INSTALL_DIR/.ghcr-user")" --password-stdin >/dev/null
fi

# Pull
if [[ "$ONLY_MIGRATE" -eq 1 ]]; then
  log "pulling migrate image"
  $COMPOSE pull migrate
elif [[ -n "$TARGETS" ]]; then
  log "pulling: $TARGETS"
  $COMPOSE pull $TARGETS
else
  log "pulling all services"
  $COMPOSE pull
fi

# Migrations (one-shot, idempotent)
if [[ "$RUN_MIGRATE" -eq 1 ]]; then
  log "running migrations"
  $COMPOSE run --rm migrate
fi

# Bring services up
if [[ "$ONLY_MIGRATE" -eq 1 ]]; then
  : # nothing else to start
elif [[ -n "$TARGETS" ]]; then
  log "restarting: $TARGETS"
  $COMPOSE up -d --no-deps --remove-orphans $TARGETS
else
  log "starting full stack"
  $COMPOSE up -d --remove-orphans
fi

# Status
sleep 5
log "container status"
$COMPOSE ps

# Prune images older than 7 days (onfood-dev images only are affected in practice)
log "pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

log "deploy complete"
