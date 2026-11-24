# Decisions

- **Caddy as the reverse proxy.** It issues and renews TLS certificates with no extra tooling. One proxy per server; it holds no company data.
- **A `files.` domain for object storage.** Signed links must be reachable by browsers. MinIO's admin console is not exposed.
- **Storage is VersityGW (`versity/versitygw:v1.11.0`, Apache 2.0) unless `S3_IMAGE` names another.** MinIO's repository is archived and its images are no longer published. Tested with the app's own S3 library on 23 November 2026, against SeaweedFS 4.55: both served signed links and refused tampered, expired, unsigned and wrongly keyed requests; VersityGW needs about 10 MB of memory instead of 167 MB, runs as any user with a read-only filesystem, and keeps plain files. **It must run with `--sidecar`:** otherwise file types and checksums are filesystem attributes, which the backups' `tar` loses. An install that already names an image keeps it. The script checks use `compose/test-s3`, which is for checks only and ignores signatures.
- **App and migration database roles are separate,** so the app cannot change the schema or disable audit triggers.
- **Rollback restores the pre-upgrade backup,** because migrations only run forward. This loses work since the upgrade, and the script says so before it runs.
- **Backups are per company and verified by checksum before restore.** `restore.sh` refuses a backup from another company.
- **Backups are installed by provisioning, encrypted with a key held off the server, and copied off-site by an operator-supplied command** (`BACKUP_OFFSITE_CMD`), so the scripts don't depend on one storage vendor. Off-site copies of unencrypted backups are refused by default.
- **Restore never drops the live database first.** It restores into `lims_restore`, checks it, and swaps by renaming.
- **The table-owner database URL lives in `migrate.env`, loaded only by the `migrate` container.** The api and worker hold only `lims_app`.
- **No generic service names across the shared proxy network.** The app reaches storage through a per-company alias; the proxy uses unique container names.
- **Secrets are generated on the server** and never leave the company's folder unless you copy them to your secrets store.

## Settings files
- **`generated.env` is written with Compose's own escapes,** not the shell's: a mail password with `$`, a quote or a backslash arrives as typed. `scripts/env-check.sh` proves it through Compose.
- **`restore.sh` empties Redis:** sessions and queued jobs belong to the data that was replaced. Everyone signs in again.
- **`deploy.sh` also writes the proxy's site,** so a changed domain takes effect.

## GST e-invoicing
- **`EINVOICE_*` are deployment settings, written into `generated.env`** like the WhatsApp and assistant settings. They hold the lab's e-invoice API credentials, so they belong in the company's `deployment.env` (outside this repository), never in git. The module stays off in the app until an Admin turns it on.

## One server on AWS
- **The budget is 200 US dollars a month, so one server with Docker Compose** (`terraform/server`). EKS cannot fit: its fixed parts cost more than that before any node. `terraform/prod` stays for when it can be afforded.
- **PostgreSQL on the server, not RDS.** The Compose set-up is the one tested end to end. Hourly snapshots of the data disk and nightly locked copies in another region stand in for point-in-time recovery: up to an hour can be lost.
- **Everything on one data disk, Docker's image store included** (`containerd-snapshotter` off), so a replaced server finds its containers, images and volumes and starts them.
- **The server can add off-site backups and nothing else;** Object Lock in compliance mode keeps them whoever asks.
- **CPU credits are `standard`:** a busy spell slows the server instead of adding to the bill.
- **A short script sends the figures, not the CloudWatch agent:** it also knows about unhealthy containers and the age of each company's backup.
- **CloudTrail, GuardDuty and the budget are their own stack** (`terraform/account`), so either setup can be used or both during a move.

## Production on AWS (Terraform)
- **EKS replaces the EC2 servers.** The servers shared one role that could read every company's files and secrets, one unhealthy company could take the others down, and their start-up script was never written. Pods get one company's identity each.
- **Terraform owns the load balancer; pods join its target groups** (TargetGroupBinding). The firewall, certificates, alarms and listener stay in one place, and the controller in the cluster may only fill target groups.
- **One root module for the shared setup, one `modules/lab` per company from a `labs` map.** Adding a company is an entry and an apply.
- **Per-company database roles** (`lims_<slug>_owner`, `lims_<slug>_app`): one RDS instance serves every company and role names are instance-wide. A company that must have its own instance needs its own copy of this setup.
- **Nodes in private subnets behind one NAT gateway,** two when outgoing calls must survive losing a zone. The database has no internet route.
- **Secrets never enter the plan or the state** (ephemeral values, write-only arguments). Integration secrets are added by hand to the same secret.
- **The pods may read and write their files and delete nothing but data exports,** which are copies. Versions and the Hyderabad copy are the backup.
- **Certificates at the top level, not in the company module,** because the HTTPS listener needs the first company's certificate before any company's routing rules can attach to it.
- **Release images are never swept from ECR:** a company may be running any of them.
- **`terraform test` plans the whole setup against mocked AWS,** in CI.

## Trial package
- **`docker-compose/` is one company on one machine at one address, over plain HTTP on localhost.** Caddy routes the API, signed file links and the screens under one origin, so no DNS or certificates are needed to look at the product. `compose/` with `scripts/` stays the way to run several companies on a server.
- **Secrets are made by the first start, in a volume,** as files the containers read. `.env` holds no passwords except an optional SMTP one, and the setup token is never in a log.
- **`scripts/trial-check.mjs` uses it as a customer would:** install, work, files, restart, backup, restore, the trial ending, and a renewal.

## Kubernetes
- **Kustomize, not Helm.** One set of manifests and a short overlay per company; nothing to install, and what is applied can be read as it is.
- **A cache per namespace,** instead of one shared ElastiCache with one password, where a company could read another's sessions. One pod with a disk: a short wait if its machine fails, for a fraction of the cost.
- **`deploy.sh` instead of an operator:** migrations as a Job first, then the new version, then back to the previous one if it does not become ready.
- **`check.sh` proves it on a real cluster:** installation, real use with a PDF, who can reach what, an upgrade, and an upgrade that does not work.
