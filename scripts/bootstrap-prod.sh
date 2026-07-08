#!/usr/bin/env bash
# One-time, non-destructive setup for OnFood production on onfood-prod.
# Does not install packages, change firewall, stop containers, prune Docker, or
# touch non-OnFood project directories.

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-prod}
INFRA_DIR=$INSTALL_DIR/infra
DEPLOY_USER=${DEPLOY_USER:-onfood-prod-deploy}
WEBROOT=${WEBROOT:-/var/www/html}

log() { echo -e "\033[1;32m[bootstrap-prod]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"
[[ -d "$INFRA_DIR" ]] || err "infra repo not found at $INFRA_DIR"

log "creating OnFood prod dirs under $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/env" "$INSTALL_DIR/backups"
mkdir -p "$WEBROOT/.well-known/acme-challenge"
mkdir -p /etc/nginx/snippets

if ! id "$DEPLOY_USER" &>/dev/null; then
  log "creating deploy user $DEPLOY_USER"
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"

log "installing OnFood nginx proxy snippet"
cp "$INFRA_DIR/nginx/snippets/onfood-proxy.conf" /etc/nginx/snippets/onfood-proxy.conf

log "installing OnFood prod backup cron"
cat > /etc/cron.d/onfood-prod-backup <<CRON
# Nightly pg_dump of the onfood-prod database, keeps last 14
0 4 * * * $DEPLOY_USER $INFRA_DIR/scripts/backup-prod.sh >> /var/log/onfood-prod-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/onfood-prod-backup

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$INSTALL_DIR"

log "bootstrap complete"
cat <<NEXT

Next:
  1. Add CI deploy public key to /home/$DEPLOY_USER/.ssh/authorized_keys
  2. Write /opt/onfood-prod/.env and env/*.prod.env from templates
  3. Write GHCR pull creds: /opt/onfood-prod/.ghcr-user + .ghcr-token
  4. Validate compose: bash $INFRA_DIR/scripts/validate-prod-compose.sh
  5. Issue certs: bash $INFRA_DIR/scripts/issue-certs-prod.sh
  6. Install nginx sites: bash $INFRA_DIR/scripts/install-nginx-sites-prod.sh
  7. First deploy: sudo -u $DEPLOY_USER bash $INFRA_DIR/scripts/deploy-prod.sh
NEXT
