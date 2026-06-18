#!/usr/bin/env bash
# issue-certs.sh — issue Let's Encrypt certs for the onfood test subdomains.
#
# Uses the webroot challenge (/var/www/html) so nginx is NEVER stopped — safe on
# this shared host where other projects serve traffic. Installs a minimal port-80
# stub vhost per domain first (so the ACME challenge resolves), then issues certs.
# Run install-nginx-sites.sh afterwards to swap in the full HTTPS vhosts.
#
# Idempotent: skips domains that already have a cert.

set -euo pipefail

DOMAINS=("test-eats.onfood.uz" "test-business.onfood.uz" "test-admin.onfood.uz" "test-api.onfood.uz" "test-cdn.onfood.uz")
WEBROOT=${WEBROOT:-/var/www/html}
EMAIL=${LETSENCRYPT_EMAIL:-salikhov.id.99@gmail.com}

log() { echo -e "\033[1;32m[certs]\033[0m $*"; }
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
  # Minimal port-80 stub so the HTTP-01 challenge resolves (no HTTPS yet).
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
  log "all certs already issued"
  exit 0
fi

log "reloading nginx with ACME stubs"
nginx -t
systemctl reload nginx

# Issue one cert per domain (separate live/<domain>/ lineage), so each nginx
# vhost references its own cert path.
for d in "${to_issue[@]}"; do
  log "issuing cert for $d"
  certbot certonly --webroot -w "$WEBROOT" \
    --non-interactive --agree-tos --email "$EMAIL" --no-eff-email \
    --keep-until-expiring --cert-name "$d" \
    -d "$d"
done

# Ensure nginx reloads after future renewals
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

log "done — now run install-nginx-sites.sh to enable the full HTTPS vhosts"
