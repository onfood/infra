#!/usr/bin/env bash
# Pull immutable production images, run migrations, restart only allowlisted
# OnFood production services, and verify the touched service routes.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-prod}
COMPOSE_FILE=$INSTALL_DIR/infra/docker-compose.prod.yml
ENV_FILE=$INSTALL_DIR/.env
COMPOSE=(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE")

SERVICE=${1:-}
IMAGE_TAG=${IMAGE_TAG:-}
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
GHCR_IMAGES=()
VERIFY_TARGETS=()

add_image() {
  local service=$1
  GHCR_IMAGES+=("ghcr.io/onfood/$service")
}

case "$SERVICE" in
  ""|full)
    PULL_TARGETS=("${INFRA_SERVICES[@]}" minio-setup migrate "${APP_SERVICES[@]}")
    UP_TARGETS=("${APP_SERVICES[@]}")
    VERIFY_TARGETS=("${APP_SERVICES[@]}")
    RUN_MIGRATE=1
    RUN_MINIO_SETUP=1
    add_image migrations
    for svc in "${APP_SERVICES[@]}"; do add_image "$svc"; done
    ;;
  infrastructure|infra)
    PULL_TARGETS=("${INFRA_SERVICES[@]}" minio-setup)
    UP_TARGETS=("${INFRA_SERVICES[@]}")
    RUN_MINIO_SETUP=1
    ;;
  backend)
    PULL_TARGETS=("${BACKEND_SERVICES[@]}")
    UP_TARGETS=("${BACKEND_SERVICES[@]}")
    VERIFY_TARGETS=("${BACKEND_SERVICES[@]}")
    RUN_MIGRATE=1
    for svc in "${BACKEND_SERVICES[@]}"; do add_image "$svc"; done
    ;;
  migrations|migrate)
    PULL_TARGETS=(migrate)
    UP_TARGETS=()
    VERIFY_TARGETS=()
    RUN_MIGRATE=1
    ONLY_MIGRATE=1
    add_image migrations
    ;;
  eats|business|adminpanel)
    PULL_TARGETS=("$SERVICE")
    UP_TARGETS=("$SERVICE")
    VERIFY_TARGETS=("$SERVICE")
    add_image "$SERVICE"
    ;;
  eats-api|business-api|eats-bot|business-bot|scheduler)
    PULL_TARGETS=("$SERVICE")
    UP_TARGETS=("$SERVICE")
    VERIFY_TARGETS=("$SERVICE")
    RUN_MIGRATE=1
    add_image "$SERVICE"
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

if [[ ${#GHCR_IMAGES[@]} -gt 0 ]]; then
  if [[ -n "${GHCR_TOKEN:-}" ]]; then
    [[ -n "${GHCR_USER:-}" ]] || err "GHCR_USER is required when GHCR_TOKEN is set"
    log "ghcr login from environment"
    docker login ghcr.io -u "$GHCR_USER" \
      --password-stdin <<<"$GHCR_TOKEN" >/dev/null
  elif [[ -f $INSTALL_DIR/.ghcr-token && -f $INSTALL_DIR/.ghcr-user ]]; then
    log "ghcr login from server credential files"
    docker login ghcr.io -u "$(cat "$INSTALL_DIR/.ghcr-user")" \
      --password-stdin < "$INSTALL_DIR/.ghcr-token" >/dev/null
  else
    err "GHCR credentials required for application image deploy"
  fi
fi

if [[ -n "$IMAGE_TAG" && ${#GHCR_IMAGES[@]} -gt 0 ]]; then
  log "pulling immutable image tag: $IMAGE_TAG"
  for image in "${GHCR_IMAGES[@]}"; do
    log "pull $image:$IMAGE_TAG"
    docker pull "$image:$IMAGE_TAG"
    docker tag "$image:$IMAGE_TAG" "$image:prod"
  done
elif [[ ${#PULL_TARGETS[@]} -gt 0 ]]; then
  log "pulling compose services: ${PULL_TARGETS[*]}"
  "${COMPOSE[@]}" pull "${PULL_TARGETS[@]}"
fi

if [[ "$SERVICE" == "" || "$SERVICE" == "full" || "$SERVICE" == "infrastructure" || "$SERVICE" == "infra" || "$SERVICE" == "minio" ]]; then
  log "starting infrastructure: ${INFRA_SERVICES[*]}"
  "${COMPOSE[@]}" up -d "${INFRA_SERVICES[@]}"
fi

if [[ "$RUN_MINIO_SETUP" -eq 1 ]]; then
  log "ensuring minio bucket/policy"
  "${COMPOSE[@]}" run --rm -T minio-setup
fi

if [[ "$RUN_MIGRATE" -eq 1 ]]; then
  log "running migrations"
  "${COMPOSE[@]}" run --rm -T migrate
fi

if [[ "$ONLY_MIGRATE" -eq 0 && ${#UP_TARGETS[@]} -gt 0 ]]; then
  log "starting/restarting: ${UP_TARGETS[*]}"
  "${COMPOSE[@]}" up -d --no-deps "${UP_TARGETS[@]}"
fi

http_status() {
  local url=$1
  curl -fsS -o /dev/null -w "%{http_code}" --max-time 20 "$url"
}

expect_http_ok() {
  local name=$1
  local url=$2
  local code
  for _ in {1..30}; do
    code=$(http_status "$url" || true)
    case "$code" in
      2*|3*) log "$name health ok ($code) $url"; return 0 ;;
    esac
    sleep 2
  done
  err "$name health failed at $url (last status: ${code:-none})"
}

verify_service() {
  case "$1" in
    eats-api) expect_http_ok eats-api "http://127.0.0.1:4020/health" ;;
    business-api) expect_http_ok business-api "http://127.0.0.1:4021/health" ;;
    eats-bot) expect_http_ok eats-bot "http://127.0.0.1:4023/health" ;;
    business-bot) expect_http_ok business-bot "http://127.0.0.1:4024/health" ;;
    eats) expect_http_ok eats "http://127.0.0.1:4010" ;;
    business) expect_http_ok business "http://127.0.0.1:4011" ;;
    adminpanel) expect_http_ok adminpanel "http://127.0.0.1:4012" ;;
    scheduler) log "scheduler has no HTTP health endpoint; compose status is checked" ;;
  esac
}

if [[ ${#VERIFY_TARGETS[@]} -gt 0 ]]; then
  log "verifying touched services"
  for svc in "${VERIFY_TARGETS[@]}"; do
    verify_service "$svc"
  done
fi

log "OnFood prod status"
"${COMPOSE[@]}" ps

log "deploy complete"
