#!/usr/bin/env bash
# bootstrap.sh — one-time, NON-DESTRUCTIVE setup for the onfood-dev stack on the
# shared tamweel host. Only additive actions — never touches the firewall,
# existing nginx sites, other projects, or installs/removes packages (docker,
# nginx, certbot, git are already present on this host).
#
#   git clone git@github.com:onfood/infra /opt/onfood-dev/infra
#   sudo bash /opt/onfood-dev/infra/scripts/bootstrap.sh

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/onfood-dev}
INFRA_DIR=$INSTALL_DIR/infra
DEPLOY_USER=${DEPLOY_USER:-onfood-deploy}
WEBROOT=/var/www/html

log() { echo -e "\033[1;32m[bootstrap]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"

# ── Directory layout ───────────────────────────────────────────────────
log "creating directories under $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/env" "$INSTALL_DIR/backups"
mkdir -p "$WEBROOT/.well-known/acme-challenge"
mkdir -p /etc/nginx/snippets

# ── Dedicated deploy user (docker group; used by CI over SSH) ───────────
if ! id "$DEPLOY_USER" &>/dev/null; then
  log "creating deploy user $DEPLOY_USER"
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"

# ── Install nginx proxy snippet ─────────────────────────────────────────
log "installing nginx snippet"
cp "$INFRA_DIR/nginx/snippets/onfood-proxy.conf" /etc/nginx/snippets/onfood-proxy.conf

# ── Ownership (deploy user runs docker compose + reads env files) ───────
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$INSTALL_DIR"

# ── Nightly backup cron (onfood_db_dev only) ────────────────────────────
log "installing nightly backup cron"
cat > /etc/cron.d/onfood-dev-backup <<CRON
# Nightly pg_dump of the onfood-dev database, keeps last 14
0 4 * * * $DEPLOY_USER $INFRA_DIR/scripts/backup.sh >> /var/log/onfood-dev-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/onfood-dev-backup

log "bootstrap complete"
echo
echo "Next:"
echo "  1. Add CI deploy public key → /home/$DEPLOY_USER/.ssh/authorized_keys"
echo "  2. Write env files → $INSTALL_DIR/{.env,env/backend.env,env/eats.env,env/business.env,env/adminpanel.env}"
echo "  3. Write GHCR pull creds → $INSTALL_DIR/.ghcr-token + $INSTALL_DIR/.ghcr-user"
echo "  4. Issue certs:        bash $INFRA_DIR/scripts/issue-certs.sh"
echo "  5. Install nginx sites: bash $INFRA_DIR/scripts/install-nginx-sites.sh"
echo "  6. First deploy:       sudo -u $DEPLOY_USER bash $INFRA_DIR/scripts/deploy.sh"
