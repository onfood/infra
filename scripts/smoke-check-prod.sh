#!/usr/bin/env bash
# OnFood production smoke checks. Safe: read-only HTTP/DB checks only.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-prod}
COMPOSE_FILE=$INSTALL_DIR/infra/docker-compose.prod.yml
ENV_FILE=$INSTALL_DIR/.env
COMPOSE=(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE")

EATS_URL=${EATS_URL:-https://eats.onfood.uz}
BUSINESS_URL=${BUSINESS_URL:-https://business.onfood.uz}
ADMIN_URL=${ADMIN_URL:-https://admin.onfood.uz}
CDN_URL=${CDN_URL:-https://cdn.onfood.uz}

log() { echo -e "\033[1;32m[smoke-prod]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

http_status() {
  curl -k -sS -o /dev/null -w "%{http_code}" --max-time 15 "$1"
}

expect_status() {
  local name=$1
  local url=$2
  local code
  code=$(http_status "$url") || err "$name failed: $url"
  case "$code" in
    2*|3*) log "$name ok ($code) $url" ;;
    *) err "$name bad status $code: $url" ;;
  esac
}

expect_any_status() {
  local name=$1
  local url=$2
  local allowed=$3
  local code
  code=$(http_status "$url") || err "$name failed: $url"
  case " $allowed " in
    *" $code "*) log "$name ok ($code) $url" ;;
    *) err "$name bad status $code, allowed: $allowed, url: $url" ;;
  esac
}

[[ -f "$COMPOSE_FILE" ]] || err "compose file missing: $COMPOSE_FILE"
[[ -f "$ENV_FILE" ]] || err "env file missing: $ENV_FILE"

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

log "compose status"
"${COMPOSE[@]}" ps

expect_status "local eats-api health" "http://127.0.0.1:4020/health"
expect_status "local business-api health" "http://127.0.0.1:4021/health"
expect_status "local eats-bot health" "http://127.0.0.1:4023/health"
expect_status "local business-bot health" "http://127.0.0.1:4024/health"
expect_status "local minio health" "http://127.0.0.1:4025/minio/health/live"

expect_status "public eats frontend" "$EATS_URL"
expect_status "public business frontend" "$BUSINESS_URL"
expect_status "public adminpanel" "$ADMIN_URL"
expect_status "public eats API" "$EATS_URL/api/v1/bot/info"
expect_status "public business API" "$BUSINESS_URL/api/v1/bot/info"
expect_any_status "public CDN route" "$CDN_URL" "200 301 302 307 400 403"

log "migration version"
"${COMPOSE[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "select version::text || ':' || dirty::text from schema_migrations order by version desc limit 1;"

if [[ -n "${SMOKE_EATS_AUTH_TOKEN:-}" ]]; then
  log "story presign path"
  curl -k -fsS --max-time 20 \
    -H "Authorization: Bearer $SMOKE_EATS_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"content_type":"video/mp4","size_bytes":1024,"duration_seconds":1}' \
    "$EATS_URL/api/v1/stories/presign" >/dev/null
else
  log "story presign path skipped; set SMOKE_EATS_AUTH_TOKEN to test authenticated upload"
fi

if [[ -n "${SMOKE_CDN_OBJECT_PATH:-}" ]]; then
  expect_status "public CDN object GET" "$CDN_URL/$SMOKE_CDN_OBJECT_PATH"
else
  log "public CDN object GET skipped; set SMOKE_CDN_OBJECT_PATH after first upload"
fi

log "smoke complete"
