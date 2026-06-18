#!/usr/bin/env bash
# install-nginx-sites.sh — install the full onfood test HTTPS vhosts + snippet.
# Idempotent. Run as root, AFTER issue-certs.sh has obtained the certificates.

set -euo pipefail

INFRA_DIR=${INFRA_DIR:-/opt/onfood-dev/infra}
SITES=("test-eats.onfood.uz" "test-business.onfood.uz" "test-admin.onfood.uz" "test-api.onfood.uz" "test-cdn.onfood.uz")

log() { echo -e "\033[1;32m[nginx]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"

log "installing proxy snippet"
mkdir -p /etc/nginx/snippets
cp "$INFRA_DIR/nginx/snippets/onfood-proxy.conf" /etc/nginx/snippets/onfood-proxy.conf

for site in "${SITES[@]}"; do
  [[ -d /etc/letsencrypt/live/$site ]] || err "no cert for $site — run issue-certs.sh first"
  log "installing $site"
  cp "$INFRA_DIR/nginx/$site.conf" "/etc/nginx/sites-available/$site"
  ln -sf "/etc/nginx/sites-available/$site" "/etc/nginx/sites-enabled/$site"
done

log "testing config"
nginx -t

log "reloading"
systemctl reload nginx

log "done"
