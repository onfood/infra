# onfood infra

Deploy configuration for OnFood test/staging and production. Images are built
in CI and pulled from GHCR; host nginx reverse-proxies each public service with
Let's Encrypt TLS.

## Production (`/opt/onfood-prod`)

Target: `onfood-prod` (`144.91.116.251`). This host already runs non-OnFood
Tamweel services. Do not touch those containers, volumes, nginx sites, ports, or
project directories.

Production files are separate from dev:

```
infra/
├── docker-compose.prod.yml
├── nginx/
│   ├── eats.onfood.uz.conf
│   ├── business.onfood.uz.conf
│   ├── admin.onfood.uz.conf
│   ├── cdn.onfood.uz.conf
│   └── snippets/onfood-proxy.conf
├── scripts/
│   ├── bootstrap-prod.sh
│   ├── deploy-prod.sh
│   ├── backup-prod.sh
│   ├── issue-certs-prod.sh
│   ├── install-nginx-sites-prod.sh
│   ├── smoke-check-prod.sh
│   └── validate-prod-compose.sh
└── env/*.prod.example
```

Server layout:

```
/opt/onfood-prod/
├── infra/
├── .env
├── env/
│   ├── backend.prod.env
│   ├── eats.prod.env
│   ├── business.prod.env
│   └── adminpanel.prod.env
├── .ghcr-token
├── .ghcr-user
└── backups/
```

Production namespacing:

| Resource | Name |
|---|---|
| Compose project | `onfood-prod` |
| Containers | `onfood-prod-*` |
| Network | `onfood_prod_internal` |
| Volumes | `onfood_prod_pg_data`, `onfood_prod_redis_data`, `onfood_prod_minio_data`, `onfood_prod_story_tmp` |
| Backup cron | `/etc/cron.d/onfood-prod-backup` |
| Backup log | `/var/log/onfood-prod-backup.log` |

Production routing:

| Hostname/path | Local target | Service |
|---|---:|---|
| `eats.onfood.uz/` | `127.0.0.1:4010` | eats |
| `eats.onfood.uz/api/v1/*` | `127.0.0.1:4020` | eats-api |
| `eats.onfood.uz/webhooks/eats` | `127.0.0.1:4023/webhook` | eats-bot |
| `business.onfood.uz/` | `127.0.0.1:4011` | business |
| `business.onfood.uz/api/v1/*` | `127.0.0.1:4021` | business-api |
| `business.onfood.uz/webhooks/business` | `127.0.0.1:4024/webhook` | business-bot |
| `admin.onfood.uz/` | `127.0.0.1:4012` | adminpanel |
| `cdn.onfood.uz/` | `127.0.0.1:4025` | MinIO |

Postgres and Redis are internal-only. They expose no host ports.

Production first setup:

```bash
ssh onfood-prod
git clone git@github.com:onfood/infra /opt/onfood-prod/infra
bash /opt/onfood-prod/infra/scripts/bootstrap-prod.sh
# write /opt/onfood-prod/.env and /opt/onfood-prod/env/*.prod.env
# write /opt/onfood-prod/.ghcr-user and /opt/onfood-prod/.ghcr-token
bash /opt/onfood-prod/infra/scripts/validate-prod-compose.sh
bash /opt/onfood-prod/infra/scripts/issue-certs-prod.sh
bash /opt/onfood-prod/infra/scripts/install-nginx-sites-prod.sh
sudo -u onfood-prod-deploy bash /opt/onfood-prod/infra/scripts/deploy-prod.sh
bash /opt/onfood-prod/infra/scripts/smoke-check-prod.sh
```

Production deploy script accepts only:

- full stack: `deploy-prod.sh` or `deploy-prod.sh full`
- infra only: `deploy-prod.sh infrastructure`
- backend group: `deploy-prod.sh backend`
- migrations only: `deploy-prod.sh migrations`
- single services: `eats`, `business`, `adminpanel`, `eats-api`,
  `business-api`, `eats-bot`, `business-bot`, `scheduler`, `minio`

Unknown service identifiers fail before Docker is touched.

Production CI/CD must build `:prod` and `:prod-<sha>` tags, use GitHub
`production` environment, then SSH to `onfood-prod` and run:

```bash
bash /opt/onfood-prod/infra/scripts/deploy-prod.sh <service>
```

Required production secrets:

- `PROD_DEPLOY_HOST` (`144.91.116.251`)
- `PROD_DEPLOY_USER`
- `PROD_DEPLOY_SSH_KEY`
- App workflows pass a short-lived GitHub Actions token to the remote deploy
  for GHCR pulls.
- Server-side `/opt/onfood-prod/.ghcr-*` remains only a manual fallback.

Production build args/secrets by repo:

| Repo | Image(s) | Deploy service | Production build args/secrets |
|---|---|---|---|
| `customer` | `ghcr.io/onfood/eats:prod`, `:prod-<sha>` | `eats` | `NEXT_PUBLIC_BACKEND_URL=https://eats.onfood.uz`, `NEXT_PUBLIC_EATS_APP_URL=https://eats.onfood.uz`, `PROD_EATS_TELEGRAM_OAUTH_CLIENT_ID`, `PROD_NEXT_PUBLIC_YANDEX_MAPS_API_KEY` |
| `business` | `ghcr.io/onfood/business:prod`, `:prod-<sha>` | `business` | `NEXT_PUBLIC_BACKEND_URL=https://business.onfood.uz`, `NEXT_PUBLIC_BUSINESS_APP_URL=https://business.onfood.uz`, `PROD_BUSINESS_TELEGRAM_OAUTH_CLIENT_ID`, `PROD_NEXT_PUBLIC_YANDEX_MAPS_API_KEY` |
| `adminpanel` | `ghcr.io/onfood/adminpanel:prod`, `:prod-<sha>` | `adminpanel` | `NEXT_PUBLIC_ADMIN_APP_URL=https://admin.onfood.uz`, `PROD_NEXT_PUBLIC_YANDEX_MAPS_API_KEY` |
| `backend` | `ghcr.io/onfood/eats-api:prod`, `business-api:prod`, `eats-bot:prod`, `business-bot:prod`, `scheduler:prod` plus `:prod-<sha>` | `backend` | `VERSION=<sha>` |
| `migrations` | `ghcr.io/onfood/migrations:prod`, `:prod-<sha>` | `migrations` | none |

Forbidden on both old and new production servers:

- `docker system prune`
- `docker image prune`
- `docker volume prune`
- `docker stop $(docker ps -q)`
- `docker compose down` from shared/unknown directories
- deleting `/var/www`, `/opt`, `/srv`, `/var/lib/docker`, or nginx site dirs
- stopping/removing Tamweel, Coolify, Hisob24, Azaly, or any non-OnFood resource

Old production rollback remains old-server restart plus DNS routing. Old
OnFood containers, volumes, env files, and data dirs must stay preserved until
cleanup is separately approved.

## Test/staging (`/opt/onfood-dev`)

Deploy configuration for the OnFood **test/staging** environment, hosted on the
shared `tamweel` server (`84.247.143.87`).

Hosts: customer (`test-eats.onfood.uz`), business (`test-business.onfood.uz`),
admin (`test-admin.onfood.uz`), API gateway (`test-api.onfood.uz`), CDN
(`test-cdn.onfood.uz`).

> History: this repo started as the "qber" production template. It has been
> repurposed for the onfood test environment on tamweel.

## Layout

```
infra/
├── docker-compose.yml          # postgres + redis + minio + 5 Go + 3 Next.js + migrate
├── nginx/
│   ├── test-eats.onfood.uz.conf
│   ├── test-business.onfood.uz.conf
│   ├── test-admin.onfood.uz.conf
│   ├── test-api.onfood.uz.conf      # path gateway: /eats, /business, /webhooks/*
│   ├── test-cdn.onfood.uz.conf      # minio
│   └── snippets/onfood-proxy.conf
├── scripts/
│   ├── bootstrap.sh            # one-time, non-destructive host setup
│   ├── issue-certs.sh          # Let's Encrypt via webroot (no nginx downtime)
│   ├── install-nginx-sites.sh  # install the HTTPS vhosts
│   ├── deploy.sh               # pull + migrate + up (called by CI)
│   └── backup.sh               # nightly pg_dump (cron)
└── env/*.example               # env templates (real files: /opt/onfood-dev/{.env,env/*.env})
```

## Server layout (`/opt/onfood-dev`)

```
/opt/onfood-dev/
├── infra/                # this repo, cloned on the server (development branch)
├── .env                  # compose-level: POSTGRES_*, MINIO_*, R2_BUCKET
├── env/
│   ├── backend.env       # all 5 Go services
│   ├── eats.env
│   ├── business.env
│   └── adminpanel.env
├── .ghcr-token           # GHCR read:packages PAT (docker login)
├── .ghcr-user            # GHCR username
└── backups/              # nightly pg_dump, last 14
```

## Routing

| Hostname | → 127.0.0.1 | Service |
|---|---|---|
| test-eats.onfood.uz | 3010 | eats (Next.js) |
| test-business.onfood.uz | 3011 | business (Next.js) |
| test-admin.onfood.uz | 3012 | adminpanel (Next.js) |
| test-cdn.onfood.uz | 3025 | minio |
| test-api.onfood.uz/eats/* | 3020 | eats-api (prefix stripped) |
| test-api.onfood.uz/business/* | 3021 | business-api (prefix stripped) |
| test-api.onfood.uz/webhooks/eats | 3023 | eats-bot (→ /webhook) |
| test-api.onfood.uz/webhooks/business | 3024 | business-bot (→ /webhook) |

Frontends call the gateway: `NEXT_PUBLIC_BACKEND_URL=https://test-api.onfood.uz/eats` (eats),
`…/business` (business). postgres/redis stay internal (no host port).

## CI/CD flow

App repos (`backend`, `eats`, `business`, `adminpanel`, `migrations`) push to the
`development` branch → each repo's `.github/workflows/deploy-dev.yml`:

1. Build docker image(s), push to `ghcr.io/onfood/<svc>:dev` (+ `:dev-<sha>`)
2. SSH to tamweel, run `bash /opt/onfood-dev/infra/scripts/deploy.sh <service>`

`<service>` is `backend` (5 Go images), `eats`, `business`, `adminpanel`, or
`migrations`.

## First-time setup

```bash
ssh tamweel    # root
git clone git@github.com:onfood/infra /opt/onfood-dev/infra
bash /opt/onfood-dev/infra/scripts/bootstrap.sh
# write /opt/onfood-dev/.env + env/*.env  (from env/*.example, fill secrets)
# write /opt/onfood-dev/.ghcr-token + .ghcr-user
bash /opt/onfood-dev/infra/scripts/issue-certs.sh
bash /opt/onfood-dev/infra/scripts/install-nginx-sites.sh
sudo -u onfood-deploy bash /opt/onfood-dev/infra/scripts/deploy.sh   # full stack
```

## Rollback

```bash
docker pull ghcr.io/onfood/eats:dev-<sha>
docker tag  ghcr.io/onfood/eats:dev-<sha> ghcr.io/onfood/eats:dev
sudo -u onfood-deploy bash /opt/onfood-dev/infra/scripts/deploy.sh eats
```

## Coexisting on tamweel (NOT touched)

This host also runs Tamweel, Hisob24, Azaly and Coolify. The onfood-dev stack
is fully namespaced (`onfood-dev-*` containers, `onfood_dev_internal` network,
127.0.0.1:30xx ports, separate nginx vhosts). bootstrap.sh never touches the
firewall, other nginx sites, or system packages.
