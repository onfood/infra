#!/usr/bin/env bash
# install-nginx-sites.sh — copy site configs into nginx and reload.
# Idempotent. Run as root.

set -euo pipefail

INFRA_DIR=${INFRA_DIR:-/opt/qber/infra}
SITES=("eats.qber.uz" "business.qber.uz" "admin.qber.uz" "api.qber.uz")

log() { echo -e "\033[1;32m[nginx]\033[0m $*"; }

for site in "${SITES[@]}"; do
  log "installing $site"
  cp "$INFRA_DIR/nginx/$site.conf" "/etc/nginx/sites-available/$site"
  ln -sf "/etc/nginx/sites-available/$site" "/etc/nginx/sites-enabled/$site"
done

log "ensuring snippet"
cp "$INFRA_DIR/nginx/snippets/qber-proxy.conf" /etc/nginx/snippets/qber-proxy.conf

log "testing config"
nginx -t

log "reloading"
systemctl reload nginx

log "done"
