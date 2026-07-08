#!/usr/bin/env bash
# Install full OnFood production HTTPS vhosts. Tests nginx before reload.

set -euo pipefail

INFRA_DIR=${INFRA_DIR:-/opt/onfood-prod/infra}
SITES=("eats.onfood.uz" "business.onfood.uz" "admin.onfood.uz" "cdn.onfood.uz")

log() { echo -e "\033[1;32m[nginx-prod]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"

log "installing proxy snippet"
mkdir -p /etc/nginx/snippets
cp "$INFRA_DIR/nginx/snippets/onfood-proxy.conf" /etc/nginx/snippets/onfood-proxy.conf

for site in "${SITES[@]}"; do
  [[ -d /etc/letsencrypt/live/$site ]] || err "no cert for $site; run issue-certs-prod.sh first"
  [[ -f "$INFRA_DIR/nginx/$site.conf" ]] || err "missing nginx template: $INFRA_DIR/nginx/$site.conf"
  log "installing $site"
  cp "$INFRA_DIR/nginx/$site.conf" "/etc/nginx/sites-available/$site"
  ln -sf "/etc/nginx/sites-available/$site" "/etc/nginx/sites-enabled/$site"
done

log "testing config"
nginx -t

log "reloading nginx"
systemctl reload nginx

log "done"
