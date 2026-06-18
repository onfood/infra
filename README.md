# onfood infra — test/staging

Deploy configuration for the OnFood **test/staging** environment, hosted on the
shared `tamweel` server (`84.247.143.87`). Images are built in CI and pulled from
GHCR; the host's nginx reverse-proxies each service with Let's Encrypt TLS.

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
