# Deployment

## What runs

Each company is one Docker Compose project, `lims-<slug>`, with its own PostgreSQL, Redis, MinIO, API, worker and UI containers and its own named volumes. Nothing is shared between companies except the reverse proxy on the server, which holds no company data.

The same `ghcr.io/avaniecocare/lims` and `lims-ui` images serve every company. Company details arrive at runtime through `company.env`.

## Server setup, once per server

Needs Docker Engine with the Compose plugin, ports 80 and 443 open, and DNS for each company pointing at the server.

```sh
git clone https://github.com/Avaniecocare/LIMS-Deploy.git /opt/lims-deploy
docker network create lims-proxy
sudo mkdir -p /srv/lims-proxy/sites /srv/lims-clients
sudo chown -R "$USER" /srv/lims-proxy /srv/lims-clients
touch /srv/lims-proxy/sites/_global.caddy
cd /opt/lims-deploy/proxy
PROXY_SITES_DIR=/srv/lims-proxy/sites docker compose up -d
```

## Company folder

Lives outside this repository, for example `/srv/lims-clients/acme`. Restrict access to it: it holds secrets.

| File | Written by | Contains |
|---|---|---|
| `company.env` | you | The company's details |
| `deployment.env` | you | Domains, mail settings and the storage image (`S3_IMAGE`) |
| `versions.env` | you, then `upgrade.sh` | Exact image versions |
| `branding/` | you | Logo and favicon |
| `secrets.env` | `provision.sh` | Generated passwords. Keep a copy in your secrets store |
| `generated.env` | scripts | Derived app settings; rewritten on each deploy |
| `versions.history` | `upgrade.sh` | Earlier versions and their pre-upgrade backups |
| `backups/` | `backup.sh` | Unless `LIMS_BACKUP_DIR` points elsewhere |

## Everyday commands

All take `--client-dir PATH`.

| Script | Purpose |
|---|---|
| `provision.sh` | Add a company. Add `--with-demo-data` only for trials |
| `deploy.sh` | Apply changed company details or settings |
| `migrate.sh` | Run pending migrations |
| `upgrade.sh --lims X --ui Y` | Back up, change versions, migrate, restart; rolls back by itself if it fails |
| `rollback.sh --yes` | Go back to the versions before the last upgrade, restoring that backup |
| `backup.sh` | Back up the database and files now |
| `install-backup-cron.sh` | Schedule a nightly backup at 02:00 |
| `restore.sh --from DIR --yes` | Replace all data with a backup |
| `remove-demo.sh --yes` | Remove demo data in one command |
| `status.sh` | Show versions and container state |

## Changing company details

Edit `company.env`, then run `deploy.sh`. If a value is invalid the API refuses to start and its log names the variable. Issued quotations, reports, invoices and credit notes keep the details stored when they were issued.

## Backups and restore

A backup is a folder holding `database.dump`, `files.tar.gz` and a `manifest.txt` with versions and checksums. Copy backup folders off the server: a server loss takes local ones with it.

To restore:

1. Choose a backup folder and check it belongs to this company (`manifest.txt`). `restore.sh` refuses another company's backup and verifies checksums.
2. Run `scripts/restore.sh --client-dir DIR --from BACKUP --yes`. This stops the app, replaces the database and files, and restarts it.
3. Sign in and check a recent job and an issued report's PDF.

A restored backup may have been taken on older images. If so, run `upgrade.sh` afterwards, or set `versions.env` to the versions in its manifest first.

## Checking a new image or storage choice

Run this on a machine with Docker before trusting a new version or `S3_IMAGE`:

```sh
LIMS_VERSION=0.1.0 LIMS_UI_VERSION=0.1.0 NEXT_LIMS_VERSION=0.2.0 S3_IMAGE=... LIMS_S3_ACCESS_KEY=... LIMS_S3_SECRET_KEY=... scripts/lifecycle-check.sh
```

It provisions two fictional companies, does real work through the images (first-run setup, sign-in, a PDF rendered by the worker and stored), then checks isolation, backup, restore, upgrade and rollback, and removes everything.

## Upgrades and rollback

Upgrade one company at a time. `upgrade.sh` backs up first and records the previous versions. Migrations only go forward, so a rollback restores that backup: **anything entered after the upgrade is lost**. Do rollbacks soon after an upgrade, or fix forward.

## Security notes

- The app connects as `lims_app`, which can read and write rows but owns no tables. Migrations run as `lims_owner`. So the app cannot disable the audit log's append-only triggers.
- Only the proxy publishes ports. PostgreSQL and Redis sit on the company's internal network. MinIO is reachable only through `files.<domain>`, for short-lived signed links.
- Secret files are created with mode 600.
