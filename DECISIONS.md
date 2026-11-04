# Decisions

- **Caddy as the reverse proxy.** It issues and renews TLS certificates with no extra tooling. One proxy per server; it holds no company data.
- **A `files.` domain for object storage.** Signed links must be reachable by browsers. MinIO's admin console is not exposed.
- **MinIO image pinned to a 2025 community release.** The project stopped publishing newer community images and macOS binaries. Any S3-compatible service can replace it by changing `S3_*` in `generated.env`.
- **App and migration database roles are separate,** so the app cannot change the schema or disable audit triggers.
- **Rollback restores the pre-upgrade backup,** because migrations only run forward. This loses work since the upgrade, and the script says so before it runs.
- **Backups are per company and verified by checksum before restore.** `restore.sh` refuses a backup from another company.
- **Secrets are generated on the server** and never leave the company's folder unless you copy them to your secrets store.
