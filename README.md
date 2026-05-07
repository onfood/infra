# qber infra

Server infrastructure for qber (food-surplus marketplace) production stack.

Hosts: customer (`eats.qber.uz`), business (`business.qber.uz`), admin (`admin.qber.uz`), backend gateway (`api.qber.uz`).

## Layout

```
infra/
├── docker-compose.yml        # full stack: postgres + 3 backends + 3 frontends + migrate
├── nginx/
│   ├── eats.qber.uz.conf
│   ├── business.qber.uz.conf
│   ├── admin.qber.uz.conf
│   ├── api.qber.uz.conf
│   └── snippets/qber-proxy.conf
├── scripts/
│   ├── bootstrap.sh          # one-time server setup
│   ├── install-nginx-sites.sh
│   ├── issue-certs.sh        # Let's Encrypt cert issuance
│   ├── deploy.sh             # pull + migrate + up (called by CI)
│   └── backup.sh             # nightly pg_dump (called by cron)
└── env/.env.example          # template for secrets (real files: env/*.env on server)
```

## Server layout

```
/opt/qber/
├── infra/                    # this repo, cloned on server
├── env/                      # per-service env files (gitignored)
│   ├── customer.env
│   ├── customer-api.env
│   ├── business.env
│   ├── business-api.env
│   ├── admin.env
│   ├── admin-api.env
│   └── ...
├── .env                      # top-level secrets (POSTGRES_* etc.)
├── .ghcr-token               # GHCR pull token for docker login
├── .ghcr-user                # GHCR username
└── backups/                  # nightly pg_dump output, last 14 kept
```

## First-time deploy (manual)

```bash
# 1. SSH to server
ssh deploy@31.220.87.237

# 2. Clone infra repo
sudo git clone https://github.com/onfood/infra /opt/qber/infra

# 3. Bootstrap (one-time)
sudo bash /opt/qber/infra/scripts/bootstrap.sh

# 4. Add env files (manually, never commit)
sudo nano /opt/qber/.env                      # POSTGRES_*
sudo nano /opt/qber/env/customer-api.env      # backend secrets
sudo nano /opt/qber/env/business-api.env
sudo nano /opt/qber/env/admin-api.env
sudo nano /opt/qber/env/customer.env          # frontend env
sudo nano /opt/qber/env/business.env
sudo nano /opt/qber/env/admin.env

# 5. GHCR pull token (read-only PAT with read:packages scope)
echo "ghp_..." | sudo tee /opt/qber/.ghcr-token >/dev/null
echo "github-username" | sudo tee /opt/qber/.ghcr-user >/dev/null

# 6. Issue certs (briefly stops nginx)
sudo bash /opt/qber/infra/scripts/issue-certs.sh

# 7. Install nginx sites + reload
sudo bash /opt/qber/infra/scripts/install-nginx-sites.sh

# 8. First deploy
sudo -u deploy bash /opt/qber/infra/scripts/deploy.sh
```

## CI/CD flow

- App repos (`customer`, `business`, `adminpanel`, `backend`, `migrations`) push to `development` branch
- Each repo's `.github/workflows/deploy.yml`:
  1. Build docker image
  2. Push to `ghcr.io/onfood/<app>:dev`
  3. SSH to server, run `bash /opt/qber/infra/scripts/deploy.sh <service>`
- Migrations repo special: also runs `migrate up` against prod DB before completing

## Routing

| Hostname | → Local container |
|---|---|
| eats.qber.uz | 127.0.0.1:3010 (customer) |
| business.qber.uz | 127.0.0.1:3011 (business) |
| admin.qber.uz | 127.0.0.1:3012 (admin) |
| api.qber.uz/customer/* | 127.0.0.1:3020 (customer-api, prefix stripped) |
| api.qber.uz/business/* | 127.0.0.1:3021 (business-api, prefix stripped) |
| api.qber.uz/admin/* | 127.0.0.1:3022 (admin-api, prefix stripped) |

Webhook URLs (Click, Telegram, etc.) point to `api.qber.uz/<role>/...`.

## Renewal

- `certbot.timer` runs every 12h, auto-renews via webroot challenge
- `nginx-reload.sh` deploy hook reloads nginx after each renewal
- Backup cron writes nightly to `/opt/qber/backups/`, keeps last 14 days

## Rollback

```bash
# Pull a specific tag instead of :dev
docker pull ghcr.io/onfood/customer:dev-<sha>
docker tag ghcr.io/onfood/customer:dev-<sha> ghcr.io/onfood/customer:dev
sudo -u deploy bash /opt/qber/infra/scripts/deploy.sh customer
```

## Removed services

This server was previously running Coolify, ollama, and 2 unused nginx sites
(`lugat.thenodir.uz`, `my.deltateam.uz`). All cleaned up before qber install.

Coexisting services (NOT touched):
- `elektr-bot` Go binary (supervisord, real prod bot)
- system PostgreSQL 14 (has `elektr_bot` real users — qber uses its own postgres-18 in container)
- workly-docs-ai Node app on :3001 (PM2)
- nginx-ui :9000
