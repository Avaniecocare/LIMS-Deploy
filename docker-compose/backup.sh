#!/bin/sh
# Everything needed to put this installation back, into backups/<time>/. Run it from this folder:
#   ./backup.sh
# The folder holds customer data and secrets: keep it, and any copy, as carefully as the installation itself.
set -eu
cd "$(dirname "$0")"
umask 077
dest="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest"
trap 'rm -rf "$dest"; echo "BACKUP FAILED; nothing was kept" >&2' EXIT
docker compose exec -T postgres pg_dump -U lims_owner -d lims -Fc > "$dest/database.dump"
docker compose exec -T postgres pg_restore --list < "$dest/database.dump" > /dev/null
docker compose run --rm -T --no-deps --entrypoint tar storage czf - -C /data . > "$dest/files.tar.gz"
docker compose run --rm -T --no-deps --entrypoint tar secrets czf - -C /run/lims . > "$dest/secrets.tar.gz"
cp .env "$dest/env"
for f in database.dump files.tar.gz secrets.tar.gz env; do [ -s "$dest/$f" ]; done
trap - EXIT
echo "$dest"
