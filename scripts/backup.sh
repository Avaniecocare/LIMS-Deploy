#!/usr/bin/env bash
# Backs up one company's database and files into its own backup folder:
#   scripts/backup.sh --client-dir /srv/lims-clients/acme
# Writes <timestamp>/database.dump, files.tar.gz and manifest.txt. Prunes past BACKUP_RETENTION_DAYS.
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
stamp="$(date +%Y%m%d-%H%M%S)"
dest="$BACKUP_DIR/$stamp"
mkdir -p "$dest"
chmod 700 "$BACKUP_DIR" "$dest"

log "Dumping database"
compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres pg_dump -U lims_owner -d lims -Fc > "$dest/database.dump"
[ -s "$dest/database.dump" ] || die "Database dump is empty"

log "Archiving files"
docker run --rm --volumes-from "$(compose ps -q minio)" -v "$dest":/out alpine:3 tar czf /out/files.tar.gz -C /data .

{
  echo "client=$CLIENT_SLUG"
  echo "created=$(date -u +%FT%TZ)"
  echo "lims=$LIMS_VERSION"
  echo "lims_ui=$LIMS_UI_VERSION"
  (cd "$dest" && shasum -a 256 database.dump files.tar.gz)
} > "$dest/manifest.txt"

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS:-30}" -exec rm -rf {} +
log "Backup written to $dest"
echo "$dest"
