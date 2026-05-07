#!/usr/bin/env bash
# issue-certs.sh — issue Let's Encrypt certs for all qber subdomains.
#
# Uses --standalone (briefly stops nginx) so we don't need an HTTP stub
# config. Run BEFORE install-nginx-sites.sh on first deploy. Subsequent
# certificate renewals happen via certbot.timer (every 12h, webroot).
#
# Idempotent: skips domains that already have certs.

set -euo pipefail

DOMAINS=("eats.qber.uz" "business.qber.uz" "admin.qber.uz" "api.qber.uz")
EMAIL=${LETSENCRYPT_EMAIL:-admin@qber.uz}

log() { echo -e "\033[1;32m[certs]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"

# Filter out domains that already have a cert
to_issue=()
for d in "${DOMAINS[@]}"; do
  if [[ -d /etc/letsencrypt/live/$d ]]; then
    log "$d already has cert, skipping"
  else
    to_issue+=("$d")
  fi
done

if [[ ${#to_issue[@]} -eq 0 ]]; then
  log "all certs already issued"
  exit 0
fi

# Stop nginx briefly so :80 is free for standalone challenge
nginx_was_running=0
if systemctl is-active --quiet nginx; then
  nginx_was_running=1
  log "stopping nginx for standalone challenge"
  systemctl stop nginx
fi
trap '[[ $nginx_was_running -eq 1 ]] && systemctl start nginx || true' EXIT

for d in "${to_issue[@]}"; do
  log "issuing cert for $d"
  certbot certonly --standalone \
    --non-interactive --agree-tos --email "$EMAIL" \
    --no-eff-email \
    -d "$d"
done

log "done. configure cert renewal hook so nginx reloads after renewal:"
cat > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

log "all certs issued"
