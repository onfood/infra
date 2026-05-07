#!/usr/bin/env bash
# bootstrap.sh — one-time server setup for qber stack.
# Run as root on a freshly cleaned-up server.
#
#   curl -fsSL https://raw.githubusercontent.com/onfood/infra/main/scripts/bootstrap.sh | bash
# OR (preferred — no opaque pipe-to-shell):
#   git clone https://github.com/onfood/infra /opt/qber/infra
#   sudo bash /opt/qber/infra/scripts/bootstrap.sh

set -euo pipefail

INSTALL_DIR=/opt/qber
INFRA_DIR=$INSTALL_DIR/infra
CERTBOT_WEBROOT=/var/www/certbot
DEPLOY_USER=deploy

log() { echo -e "\033[1;32m[bootstrap]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must run as root"

# ── 1. Packages ────────────────────────────────────────────────────────
log "installing required packages"
apt-get update -qq
apt-get install -y -qq \
  ufw curl jq git ca-certificates \
  certbot python3-certbot-nginx \
  postgresql-client cron rsync

# ── 2. Firewall ────────────────────────────────────────────────────────
log "configuring ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
ufw allow 80/tcp comment 'http acme + redirect'
ufw allow 443/tcp comment 'https'
# Keep nginx-ui open if user uses it; remove if not
ufw allow 9000/tcp comment 'nginx-ui'
ufw --force enable
ufw status verbose

# ── 3. Directory layout ────────────────────────────────────────────────
log "creating directories"
mkdir -p $INSTALL_DIR
mkdir -p $INSTALL_DIR/env
mkdir -p $INSTALL_DIR/backups
mkdir -p $CERTBOT_WEBROOT
mkdir -p /etc/nginx/snippets

# ── 4. Deploy user (rootless deploys after bootstrap) ──────────────────
if ! id $DEPLOY_USER &>/dev/null; then
  log "creating deploy user"
  useradd -m -s /bin/bash $DEPLOY_USER
  usermod -aG docker $DEPLOY_USER
  mkdir -p /home/$DEPLOY_USER/.ssh
  chmod 700 /home/$DEPLOY_USER/.ssh
  touch /home/$DEPLOY_USER/.ssh/authorized_keys
  chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
  chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
fi
chown -R $DEPLOY_USER:$DEPLOY_USER $INSTALL_DIR

# ── 5. Certbot baseline (first run installs ssl-dhparams + options-ssl) ─
log "ensuring certbot ssl baseline"
[[ -f /etc/letsencrypt/options-ssl-nginx.conf ]] || \
  curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
    -o /etc/letsencrypt/options-ssl-nginx.conf
[[ -f /etc/letsencrypt/ssl-dhparams.pem ]] || \
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048

# ── 6. Install nginx proxy snippet ─────────────────────────────────────
log "installing nginx snippet"
cp $INFRA_DIR/nginx/snippets/qber-proxy.conf /etc/nginx/snippets/qber-proxy.conf

# ── 7. Backup cron (nightly pg_dump of qber db only — never touches elektr_bot) ─
log "setting up nightly backup cron"
cat > /etc/cron.d/qber-backup <<'CRON'
# Nightly pg_dump of qber database into /opt/qber/backups, keeps last 14
0 3 * * * deploy /opt/qber/infra/scripts/backup.sh >> /var/log/qber-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/qber-backup

# ── 8. Done ────────────────────────────────────────────────────────────
log "bootstrap complete"
echo
echo "Next steps:"
echo "  1. Add deploy user public key to /home/$DEPLOY_USER/.ssh/authorized_keys"
echo "  2. Copy env files into $INSTALL_DIR/env/{customer,business,admin,customer-api,business-api,admin-api}.env"
echo "  3. Issue Let's Encrypt certs: bash $INFRA_DIR/scripts/issue-certs.sh"
echo "  4. Symlink nginx site files: bash $INFRA_DIR/scripts/install-nginx-sites.sh"
echo "  5. First deploy: bash $INFRA_DIR/scripts/deploy.sh"
