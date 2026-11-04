#!/usr/bin/env bash
# Replaces one company's database and files with a backup. Stops its app while restoring.
#   scripts/restore.sh --client-dir /srv/lims-clients/acme --from /path/to/backup/<timestamp> --yes
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
FROM=""; YES=false
set -- ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --yes) YES=true; shift ;;
    *) die "Unknown option $1" ;;
  esac
done
[ -n "$FROM" ] && [ -f "$FROM/database.dump" ] && [ -f "$FROM/files.tar.gz" ] || die "--from must point at a backup folder"
if ! grep -q "^client=$CLIENT_SLUG$" "$FROM/manifest.txt"; then die "That backup belongs to a different company"; fi
(cd "$FROM" && grep -E '  (database.dump|files.tar.gz)$' manifest.txt | shasum -a 256 -c -) || die "Backup failed its checksum"
[ "$YES" = true ] || die "This overwrites all data for $CLIENT_SLUG. Re-run with --yes to confirm."

log "Stopping the app"
compose stop api worker ui
compose up -d --wait postgres redis minio

log "Restoring database"
compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres psql -U lims_owner -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'lims' AND pid <> pg_backend_pid();" -c "DROP DATABASE lims;" -c "CREATE DATABASE lims OWNER lims_owner;" -c "GRANT CONNECT ON DATABASE lims TO lims_app;" >/dev/null
compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres psql -U lims_owner -d lims -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
GRANT USAGE ON SCHEMA public TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO lims_app;
SQL
compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres pg_restore -U lims_owner -d lims --no-owner --role=lims_owner --exit-on-error < "$FROM/database.dump"

log "Restoring files"
compose stop minio
docker run --rm --volumes-from "$(compose ps -aq minio)" -v "$FROM":/in:ro alpine:3 sh -c 'find /data -mindepth 1 -delete && tar xzf /in/files.tar.gz -C /data'
compose up -d --wait minio

log "Restarting"
compose up -d api worker ui
wait_healthy || die "The API did not become healthy after restore"
log "Restore complete from $FROM"
