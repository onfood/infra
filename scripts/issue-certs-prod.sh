#!/usr/bin/env bash
# Issue Let's Encrypt certs for current OnFood production domains via webroot.
# Nginx is never stopped. Only OnFood domain stubs are written.

set -euo pipefail

DOMAINS=("eats.onfood.uz" "business.onfood.uz" "admin.onfood.uz" "cdn.onfood.uz")
WEBROOT=${WEBROOT:-/var/www/html}
EMAIL=${LETSENCRYPT_EMAIL:-salikhov.id.99@gmail.com}

log() { echo -e "\033[1;32m[certs-prod]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"

mkdir -p "$WEBROOT/.well-known/acme-challenge"

to_issue=()
for d in "${DOMAINS[@]}"; do
  if [[ -d /etc/letsencrypt/live/$d ]]; then
    log "$d already has cert, skipping"
    continue
  fi
  to_issue+=("$d")
  cat > "/etc/nginx/sites-available/$d" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $d;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 404; }
}
EOF
  ln -sf "/etc/nginx/sites-available/$d" "/etc/nginx/sites-enabled/$d"
done

if [[ ${#to_issue[@]} -eq 0 ]]; then
  log "all prod certs already issued"
  exit 0
fi

log "testing nginx with ACME stubs"
nginx -t
systemctl reload nginx

for d in "${to_issue[@]}"; do
  log "issuing cert for $d"
  certbot certonly --webroot -w "$WEBROOT" \
    --non-interactive --agree-tos --email "$EMAIL" --no-eff-email \
    --keep-until-expiring --cert-name "$d" \
    -d "$d"
done

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/onfood-prod-nginx-reload.sh <<'HOOK'
#!/bin/sh
nginx -t && systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/onfood-prod-nginx-reload.sh

log "done; run install-nginx-sites-prod.sh next"
