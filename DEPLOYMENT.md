# Deployment

## What runs

Each company is one Docker Compose project, `lims-<slug>`, with its own PostgreSQL, Redis, S3-compatible store (the `minio` service, running whatever `S3_IMAGE` names), API, worker and UI containers and its own named volumes. Nothing is shared between companies except the reverse proxy on the server and its `lims-proxy` network, which hold no company data.

Every container logs to Docker's `json-file` driver with rotation (10 MB × 3 files per container), so logs cannot fill the disk. Every container has a memory cap; see [Memory](#memory).

The same `ghcr.io/avaniecocare/lims` and `lims-ui` images serve every company. Company details arrive at runtime through `company.env`.

## Server setup, once per server

Needs Docker Engine with the Compose plugin, `cron`, ports 80 and 443 open, and DNS for each company pointing at the server. For encrypted backups install `age` (recommended) or `gpg`; for off-site copies, the tool your `BACKUP_OFFSITE_CMD` uses (for example `rclone` or the AWS CLI). The user who runs the scripts must be in the `docker` group, because the nightly backup runs from that user's crontab.

The images are private on GHCR: `docker login ghcr.io` once, with a token that can read packages.

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
| `generated.env` | scripts | Derived app settings for the api and worker; rewritten on each deploy. Holds only the `lims_app` database role |
| `migrate.env` | scripts | The table-owner (`lims_owner`) database URL. Loaded **only** by the one-off `migrate` container; rewritten on each deploy |
| `backup.log` | nightly backup | Output of the cron job; rotated at 5 MB |
| `versions.history` | `upgrade.sh` | Earlier versions and their pre-upgrade backups |
| `backups/` | `backup.sh` | Unless `LIMS_BACKUP_DIR` points elsewhere |

## Everyday commands

All take `--client-dir PATH`.

| Script | Purpose |
|---|---|
| `provision.sh` | Add a company and install its nightly backup. Add `--with-demo-data` only for trials. Fails if images cannot be pulled, unless `--offline` |
| `deploy.sh` | Apply changed company details or settings |
| `migrate.sh` | Run pending migrations |
| `upgrade.sh --lims X --ui Y` | Back up, change versions, migrate, restart; rolls back by itself if it fails |
| `rollback.sh --yes` | Go back to the versions before the last upgrade, restoring that backup |
| `backup.sh` | Back up the database, files and company settings now |
| `install-backup-cron.sh` | (Re)install the nightly backup at 02:00; `provision.sh` already does this. `--check-only` reports whether it is installed |
| `restore.sh --from BACKUP --yes` | Replace all data with a backup (folder or encrypted archive) |
| `remove-demo.sh --yes` | Remove demo data in one command |
| `status.sh` | Show versions and container state |

## Changing company details

Edit `company.env`, then run `deploy.sh`. If a value is invalid the API refuses to start and its log names the variable. Issued quotations, reports, invoices and credit notes keep the details stored when they were issued.

## Memory

Each container has a memory cap, so one company's PDF rendering or a large query cannot make the kernel kill another company's database. Defaults, about 2.8 GB per company:

| Container | Variable | Default |
|---|---|---|
| postgres | `POSTGRES_MEM_LIMIT` | 512m |
| redis | `REDIS_MEM_LIMIT` | 128m |
| storage (`minio`) | `S3_MEM_LIMIT` | 256m |
| api | `API_MEM_LIMIT` | 768m |
| worker (Chromium for PDFs, 256 MB `/dev/shm`) | `WORKER_MEM_LIMIT` | 1g |
| ui | `UI_MEM_LIMIT` | 64m |
| caddy (once per server) | `CADDY_MEM_LIMIT` | 128m |

Override any of them in `deployment.env` and run `deploy.sh`. Size the server for the sum over all companies plus the OS. A container that reaches its cap is killed and restarted by Docker (`docker inspect` shows `OOMKilled`); raise that one cap.

## Health checks

PostgreSQL, Redis, the storage container, the API (`/health/live`), the worker (can reach Redis) and the UI (`/healthz`) all have Docker health checks; `status.sh` shows them. The API and worker start only once storage answers. The storage check probes port 9000 with whatever the image has (curl, wget, node or nc, through `/bin/sh`); if your `S3_IMAGE` has none of those, set `S3_HEALTHCHECK_CMD` in `deployment.env`.

For alerting, point an external uptime monitor at `https://<api domain>/health/ready` and the app domain, and set `BACKUP_PING_URL` (below).

## Backups

`provision.sh` installs a nightly backup (02:00, the provisioning user's crontab). Each run of `backup.sh` writes, under `backups/` (or `LIMS_BACKUP_DIR`):

| Item | Contents |
|---|---|
| `database.dump` | `pg_dump` custom format; checked with `pg_restore --list` before the backup counts as good |
| `files.tar.gz` | Everything in the storage volume |
| `config.tar.gz` | `company.env`, `deployment.env`, `secrets.env`, `versions.env`, `versions.history`, `branding/`: what a new server needs |
| `manifest.txt` | Company, image versions, SHA-256 of the three files |

If any step fails, `backup.sh` removes the partial backup, prints a line starting `BACKUP FAILED` with the step, and exits non-zero. Old backups past `BACKUP_RETENTION_DAYS` (default 30) are deleted only after a good backup. The database and the files are captured one after the other, not as one snapshot; stored files are only ever added, so at worst a file uploaded during the backup is present without its record.

### Encryption

A backup holds customer data, password hashes and `secrets.env`. Set one of these in `deployment.env`:

| Setting | Effect |
|---|---|
| `BACKUP_AGE_RECIPIENT="age1..."` | Encrypt to one or more [age](https://age-encryption.org) public keys (space-separated). Recommended |
| `BACKUP_GPG_RECIPIENT="ops@..."` | Encrypt to a gpg public key in the backup user's keyring |
| `BACKUP_GPG_PASSPHRASE_FILE="/path"` | Symmetric gpg with the passphrase in that file (mode 600) |

With encryption on, each backup becomes one file, `<timestamp>.tar.age` or `<timestamp>.tar.gpg`, and the plain folder is removed. Keep the **private** key (age identity / gpg secret key) off the server, in your secrets store; the server needs only the public key to write backups. The backup `upgrade.sh` takes just before an upgrade also stays as a plain folder, so an automatic rollback works without the private key; it is pruned with the rest.

Create an age key pair on your own machine: `age-keygen -o lims-backup-key.txt` prints the public key to put in `BACKUP_AGE_RECIPIENT`.

### Off-site copy

Set `BACKUP_OFFSITE_CMD` in `deployment.env`. It runs after each nightly backup with `$BACKUP_FILE` (the encrypted archive), `$BACKUP_NAME` and `$CLIENT_SLUG` set. Use **single quotes** so those are filled in at run time:

```sh
BACKUP_OFFSITE_CMD='rclone copy "$BACKUP_FILE" offsite:lims-backups/$CLIENT_SLUG/'
BACKUP_OFFSITE_CMD='aws s3 cp "$BACKUP_FILE" "s3://example-lims-backups/$CLIENT_SLUG/"'
```

An off-site copy of an unencrypted backup is refused unless `BACKUP_OFFSITE_ALLOW_PLAINTEXT="true"`. If the copy fails, the local backup is kept and the run still exits non-zero. Set retention for off-site copies in the destination (for example a bucket lifecycle rule), and use credentials that can write but not delete.

### Alerting

`BACKUP_PING_URL` is fetched after every fully successful run (local backup, off-site copy). Use a dead-man's-switch service (for example healthchecks.io) that alerts when the daily ping does not arrive. Failures also land in `backup.log` in the company folder.

## Restore

```sh
scripts/restore.sh --client-dir DIR --from BACKUP --yes [--keep-previous]
```

`BACKUP` is a backup folder or an encrypted archive. To decrypt, set `BACKUP_AGE_IDENTITY_FILE` (age private key), have the gpg secret key in the keyring, or set `BACKUP_GPG_PASSPHRASE_FILE`, in the environment or `deployment.env` on the machine doing the restore. Then `restore.sh`:

1. Refuses another company's backup and verifies the checksums.
2. Restores the dump into a temporary database, `lims_restore`, while the app keeps running, and checks it (tables present, migrations recorded, the app role can read it). If any of that fails, it stops: **the live database is never touched**.
3. Stops the app and swaps the databases by renaming, in one transaction. The live database becomes `lims_pre_restore_<time>`.
4. Unpacks the files next to the live ones in the storage volume, then swaps them in (the volume needs room for both copies for a moment).
5. Runs migrations, because the backup may predate the current images, then starts the app and waits for it to be healthy.
6. Drops `lims_pre_restore_<time>`, unless `--keep-previous`. If step 5 fails, it is kept and the script prints the command that puts it back.

Afterwards, sign in and check a recent job and an issued report's PDF. `restore.sh` does not change `company.env`, `secrets.env` or other settings. A backup taken on **newer** images than the ones in `versions.env` cannot be migrated backwards: set `versions.env` to the versions in its `manifest.txt` first.

### Restore drill

Once a month, restore the latest off-site backup onto a spare machine or a throwaway company folder and sign in. A backup nobody has restored is not yet a backup.

### Rebuilding on a new server

1. Set up the server as above and clone this repository.
2. Copy the latest backup from off-site and decrypt it on a trusted machine: `age -d -i lims-backup-key.txt <timestamp>.tar.age | tar -x` (or `gpg -d ... | tar -x`).
3. Create the company folder and unpack the settings into it: `tar -xzf <timestamp>/config.tar.gz -C /srv/lims-clients/<slug>`. This brings back `secrets.env`, so the same passwords are used.
4. Run `provision.sh --client-dir /srv/lims-clients/<slug>`, then `restore.sh --client-dir ... --from <timestamp> --yes`.
5. Point DNS at the new server.

## Checking a new image or storage choice

Run this on a machine with Docker before trusting a new version or `S3_IMAGE`:

```sh
LIMS_VERSION=0.1.0 LIMS_UI_VERSION=0.1.0 NEXT_LIMS_VERSION=0.2.0 S3_IMAGE=... LIMS_S3_ACCESS_KEY=... LIMS_S3_SECRET_KEY=... scripts/lifecycle-check.sh
```

It provisions two fictional companies, does real work through the images (first-run setup, sign-in, a PDF rendered by the worker and stored), then checks isolation, backup, restore, upgrade and rollback, and removes everything.

## Upgrades and rollback

Upgrade one company at a time. `upgrade.sh` pulls the new images first (a wrong tag stops it before anything changes), then backs up and records the previous versions. Migrations only go forward, so a rollback restores that backup: **anything entered after the upgrade is lost**. Do rollbacks soon after an upgrade, or fix forward.

## Security notes

- The app connects as `lims_app`, which can read and write rows but owns no tables. Migrations run as `lims_owner`, whose URL lives only in `migrate.env`, which only the one-off `migrate` container loads. The api and worker containers never hold it, so the app cannot disable the audit log's append-only triggers. Demo data is loaded and removed through the same `migrate` container. After updating this repository on an existing server, run `deploy.sh` once per company so running containers drop the old combined file.
- Only the proxy publishes ports. PostgreSQL and Redis sit on the company's internal network. The storage container is reachable from outside only through `files.<domain>`, and Caddy passes only signed `GET`/`HEAD` requests (an `X-Amz-Signature` query); every other S3 or admin request gets 403.
- The `api`, `ui` and storage containers of every company share the `lims-proxy` network, where Compose's generic service names (`api`, `ui`, `minio`) resolve to *any* company's container. Nothing uses those names: the proxy uses unique container names (`lims-<slug>-api-1`), and the app reaches its storage as `lims-<slug>-storage`, an alias on the company's own internal network only.
- `deployment.env` and `secrets.env` are read as shell by the scripts. Only trusted operators should be able to edit them.
- Secret files are created with mode 600.
