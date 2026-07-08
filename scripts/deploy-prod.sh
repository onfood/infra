#!/usr/bin/env bash
# Pull images, run migrations, and restart only OnFood production services.
# Unknown service names fail before Docker is touched.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-prod}
COMPOSE_FILE=$INSTALL_DIR/infra/docker-compose.prod.yml
ENV_FILE=$INSTALL_DIR/.env
COMPOSE=(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE")

SERVICE=${1:-}
INFRA_SERVICES=(postgres redis minio)
BACKEND_SERVICES=(eats-api business-api eats-bot business-bot scheduler)
FRONTEND_SERVICES=(eats business adminpanel)
APP_SERVICES=("${BACKEND_SERVICES[@]}" "${FRONTEND_SERVICES[@]}")

log() { echo -e "\033[1;32m[deploy-prod]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ -f "$COMPOSE_FILE" ]] || err "compose file missing: $COMPOSE_FILE"
[[ -f "$ENV_FILE" ]] || err "env file missing: $ENV_FILE"

cd "$INSTALL_DIR"

RUN_MIGRATE=0
ONLY_MIGRATE=0
RUN_MINIO_SETUP=0
PULL_TARGETS=()
UP_TARGETS=()

case "$SERVICE" in
  ""|full)
    PULL_TARGETS=("${INFRA_SERVICES[@]}" minio-setup migrate "${APP_SERVICES[@]}")
    UP_TARGETS=("${APP_SERVICES[@]}")
    RUN_MIGRATE=1
    RUN_MINIO_SETUP=1
    ;;
  infrastructure|infra)
    PULL_TARGETS=("${INFRA_SERVICES[@]}" minio-setup)
    UP_TARGETS=("${INFRA_SERVICES[@]}")
    RUN_MINIO_SETUP=1
    ;;
  backend)
    PULL_TARGETS=(migrate "${BACKEND_SERVICES[@]}")
    UP_TARGETS=("${BACKEND_SERVICES[@]}")
    RUN_MIGRATE=1
    ;;
  migrations|migrate)
    PULL_TARGETS=(migrate)
    RUN_MIGRATE=1
    ONLY_MIGRATE=1
    ;;
  eats|business|adminpanel)
    PULL_TARGETS=("$SERVICE")
    UP_TARGETS=("$SERVICE")
    ;;
  eats-api|business-api|eats-bot|business-bot|scheduler)
    PULL_TARGETS=(migrate "$SERVICE")
    UP_TARGETS=("$SERVICE")
    RUN_MIGRATE=1
    ;;
  minio)
    PULL_TARGETS=(minio minio-setup)
    UP_TARGETS=(minio)
    RUN_MINIO_SETUP=1
    ;;
  *)
    err "unknown production service '$SERVICE'"
    ;;
esac

if [[ -f $INSTALL_DIR/.ghcr-token && -f $INSTALL_DIR/.ghcr-user ]]; then
  log "ghcr login"
  docker login ghcr.io -u "$(cat "$INSTALL_DIR/.ghcr-user")" \
    --password-stdin < "$INSTALL_DIR/.ghcr-token" >/dev/null
fi

log "pulling: ${PULL_TARGETS[*]}"
"${COMPOSE[@]}" pull "${PULL_TARGETS[@]}"

if [[ "$SERVICE" == "" || "$SERVICE" == "full" || "$SERVICE" == "infrastructure" || "$SERVICE" == "infra" || "$SERVICE" == "minio" ]]; then
  log "starting infrastructure: ${INFRA_SERVICES[*]}"
  "${COMPOSE[@]}" up -d "${INFRA_SERVICES[@]}"
fi

if [[ "$RUN_MINIO_SETUP" -eq 1 ]]; then
  log "ensuring minio bucket/policy"
  "${COMPOSE[@]}" run --rm minio-setup
fi

if [[ "$RUN_MIGRATE" -eq 1 ]]; then
  log "running migrations"
  "${COMPOSE[@]}" run --rm migrate
fi

if [[ "$ONLY_MIGRATE" -eq 0 && ${#UP_TARGETS[@]} -gt 0 ]]; then
  log "starting/restarting: ${UP_TARGETS[*]}"
  "${COMPOSE[@]}" up -d --no-deps "${UP_TARGETS[@]}"
fi

sleep 5
log "OnFood prod status"
"${COMPOSE[@]}" ps

log "deploy complete"
