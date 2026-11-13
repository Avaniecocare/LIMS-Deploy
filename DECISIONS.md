# Decisions

- **Caddy as the reverse proxy.** It issues and renews TLS certificates with no extra tooling. One proxy per server; it holds no company data.
- **A `files.` domain for object storage.** Signed links must be reachable by browsers. MinIO's admin console is not exposed.
- **The storage image is a required setting, `S3_IMAGE`, with no default.** In November 2026 `minio/minio` no longer exists on Docker Hub, and Quay and GHCR returned nothing usable, so nothing can be assumed. Each deployment names an S3-compatible image, pinned to a version, that keeps data in `/data` and listens on 9000; a non-MinIO image can set `S3_COMMAND` too. The script checks use `compose/test-s3`, which is for checks only and not for production. **The chosen production image still needs vetting and a run of `lifecycle-check.sh`.**
- **App and migration database roles are separate,** so the app cannot change the schema or disable audit triggers.
- **Rollback restores the pre-upgrade backup,** because migrations only run forward. This loses work since the upgrade, and the script says so before it runs.
- **Backups are per company and verified by checksum before restore.** `restore.sh` refuses a backup from another company.
- **Backups are installed by provisioning, encrypted with a key held off the server, and copied off-site by an operator-supplied command** (`BACKUP_OFFSITE_CMD`), so the scripts don't depend on one storage vendor. Off-site copies of unencrypted backups are refused by default.
- **Restore never drops the live database first.** It restores into `lims_restore`, checks it, and swaps by renaming.
- **The table-owner database URL lives in `migrate.env`, loaded only by the `migrate` container.** The api and worker hold only `lims_app`.
- **No generic service names across the shared proxy network.** The app reaches storage through a per-company alias; the proxy uses unique container names.
- **Secrets are generated on the server** and never leave the company's folder unless you copy them to your secrets store.

## GST e-invoicing
- **`EINVOICE_*` are deployment settings, written into `generated.env`** like the WhatsApp and assistant settings. They hold the lab's e-invoice API credentials, so they belong in the company's `deployment.env` (outside this repository), never in git. The module stays off in the app until an Admin turns it on.

## Production on AWS (Terraform)
- **One root module for the shared setup, one `modules/lab` per company from a `labs` map.** Adding a company is an entry and an apply; its number (1-15, never reused) fixes its Redis database, host ports and routing priority, so companies never collide on shared servers, cache or load balancer.
- **Per-company database roles** (`lims_<slug>_owner`, `lims_<slug>_app`): one RDS instance serves every company and role names are instance-wide.
- **Certificates at the top level, not in the company module,** because the HTTPS listener needs the first company's certificate before any company's routing rules can attach to it (otherwise a dependency cycle).
- **App servers in public subnets, reachable only from the load balancer,** instead of private subnets with NAT gateways (US$35-45 a month each). Database and cache stay private with no internet route.
- **Generated secrets live in the encrypted, versioned state bucket; integration secrets are put in SSM by hand** so they never enter state. Buckets carry `prevent_destroy`; removing a company is a written procedure, not a plan side effect.
- **`app_servers_enabled` defaults to false** until the app changes in the runbook exist; everything else can be built and checked first. `terraform test` plans the whole setup against mocked AWS, which caught validation records keyed by apply-time values before any real plan.
