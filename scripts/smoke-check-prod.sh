#!/usr/bin/env bash
# OnFood production smoke checks. Safe: read-only HTTP/DB checks only.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-prod}
COMPOSE_FILE=$INSTALL_DIR/infra/docker-compose.prod.yml
ENV_FILE=$INSTALL_DIR/.env
BACKEND_ENV_FILE=$INSTALL_DIR/env/backend.prod.env
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
[[ -f "$BACKEND_ENV_FILE" ]] || err "backend env file missing: $BACKEND_ENV_FILE"

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
# shellcheck source=/dev/null
source "$BACKEND_ENV_FILE"
set +a

log "compose status"
"${COMPOSE[@]}" ps
"${COMPOSE[@]}" ps --status running --services | grep -qx scheduler || err "scheduler is not running"
scheduler_health=$(docker inspect -f '{{.State.Health.Status}}' onfood-prod-scheduler)
[[ "$scheduler_health" == "healthy" ]] || err "scheduler health is $scheduler_health"
log "scheduler runtime healthy"

expect_status "local eats-api health" "http://127.0.0.1:4020/health"
expect_status "local business-api health" "http://127.0.0.1:4021/health"
expect_status "local eats-bot health" "http://127.0.0.1:4023/health"
expect_status "local business-bot health" "http://127.0.0.1:4024/health"
expect_status "local minio health" "http://127.0.0.1:4025/minio/health/live"

private_code=$(http_status "$CDN_URL/$STORY_PRIVATE_S3_BUCKET/__onfood_unsigned_private_probe__") || err "private bucket probe failed"
[[ "$private_code" == "403" ]] || err "unsigned private bucket status $private_code, want 403"
log "unsigned private bucket denied (403)"

expect_status "public eats frontend" "$EATS_URL"
expect_status "public business frontend" "$BUSINESS_URL"
expect_status "public adminpanel" "$ADMIN_URL"
expect_status "public eats API" "$EATS_URL/api/v1/bot/info"
expect_status "public business API" "$BUSINESS_URL/api/v1/bot/info"
expect_any_status "public CDN route" "$CDN_URL" "200 301 302 307 400 403"

log "migration version"
"${COMPOSE[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "select version::text || ':' || dirty::text from schema_migrations order by version desc limit 1;"

queue_health=$("${COMPOSE[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -AtF '|' -c "
  SELECT
    (SELECT count(*) FROM eats_order_review_media WHERE processing_status = 2 AND processing_lease_expires_at <= now() - interval '5 minutes'),
    (SELECT count(*) FROM story_media WHERE processing_status = 2 AND processing_lease_expires_at <= now() - interval '5 minutes'),
    (SELECT count(*) FROM story_publication_jobs WHERE status = 2 AND lease_expires_at <= now() - interval '5 minutes'),
    (SELECT count(*) FROM story_object_cleanup_jobs WHERE status = 2 AND lease_expires_at <= now() - interval '75 minutes'),
    (SELECT count(*) FROM story_telegram_deliveries WHERE status = 5 AND lease_expires_at <= now() - interval '5 minutes');
")
IFS='|' read -r stale_review stale_story stale_publication stale_cleanup stale_delivery <<<"$queue_health"
for count in "$stale_review" "$stale_story" "$stale_publication" "$stale_cleanup" "$stale_delivery"; do
  [[ "$count" == "0" ]] || err "scheduler queue has stale leased work: $queue_health"
done
log "scheduler queues healthy (no stale leases)"

smoke_story_id=${SMOKE_STORY_ID:-$("${COMPOSE[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "select s.id from user_stories s join story_media m on m.story_id=s.id where s.status in (5,6,7) and m.processing_status=3 order by s.id desc limit 1;")}
if [[ -n "$smoke_story_id" ]]; then
  media_response=$(curl -fsS --max-time 15 \
    -H "X-Onfood-Internal-Secret: $STORY_MODERATION_INTERNAL_SECRET" \
    "http://127.0.0.1:4020/internal/v1/stories/$smoke_story_id/media-link?artifact=poster")
  signed_url=$(printf '%s' "$media_response" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p' | sed 's/\\u0026/\&/g')
  [[ -n "$signed_url" ]] || err "signed private media response had no URL"
  signed_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$signed_url")
  unset media_response signed_url
  [[ "$signed_code" == "200" ]] || err "signed private media read status $signed_code, want 200"
  log "signed private media read ok (200)"
else
  log "signed private media read skipped; no ready story fixture"
fi

hls_url=$("${COMPOSE[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "select m.hls_master_url from user_stories s join story_media m on m.story_id=s.id where s.status=6 and m.hls_master_url is not null order by s.approved_at desc nulls last limit 1;")
if [[ -n "$hls_url" ]]; then
  hls_master=$(mktemp)
  hls_variant=$(mktemp)
  curl -fsS --max-time 15 -o "$hls_master" "$hls_url"
  grep -q '^#EXTM3U' "$hls_master" || { rm -f "$hls_master" "$hls_variant"; err "approved HLS master is invalid"; }
  variant_ref=$(grep -v '^#' "$hls_master" | sed '/^[[:space:]]*$/d' | head -n 1)
  [[ -n "$variant_ref" && "$variant_ref" != *"://"* && "$variant_ref" != /* ]] || {
    rm -f "$hls_master" "$hls_variant"
    err "approved HLS variant reference is unsafe"
  }
  curl -fsS --max-time 15 -o "$hls_variant" "${hls_url%/*}/$variant_ref"
  grep -q '^#EXTM3U' "$hls_variant" || { rm -f "$hls_master" "$hls_variant"; err "approved HLS variant is invalid"; }
  rm -f "$hls_master" "$hls_variant"
  unset hls_url
  log "approved public HLS master ok"
else
  log "approved public HLS check skipped; no approved story fixture"
fi

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
