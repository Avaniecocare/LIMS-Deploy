#!/usr/bin/env bash
# Replaces one company's database and files with a backup.
#   scripts/restore.sh --client-dir /srv/lims-clients/acme --from BACKUP --yes [--keep-previous]
# BACKUP is a backup folder (<timestamp>/) or an encrypted archive (<timestamp>.tar.age / .tar.gpg).
# Decrypting needs BACKUP_AGE_IDENTITY_FILE (age private key), the gpg secret key in this user's
# keyring, or BACKUP_GPG_PASSPHRASE_FILE, as configured in deployment.env or the environment.
#
# Order, so a bad backup never costs the live data:
#   1. verify company and checksums
#   2. restore into a temporary database (lims_restore) while the app keeps running, and check it
#   3. stop the app, swap databases by renaming (the live one becomes lims_pre_restore_<stamp>)
#   4. unpack the files beside the live ones, then swap them in
#   5. run migrations (the backup may predate the current images), start the app, wait for health
#   6. drop lims_pre_restore_<stamp>, unless --keep-previous
# company.env, secrets.env and the other settings are NOT overwritten; config.tar.gz in the backup
# is for rebuilding on a new server (see DEPLOYMENT.md).
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
FROM=""; YES=false; KEEP_PREVIOUS=false
set -- ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --yes) YES=true; shift ;;
    --keep-previous) KEEP_PREVIOUS=true; shift ;;
    "") shift ;;
    *) die "Unknown option $1" ;;
  esac
done
[ -n "$FROM" ] || die "--from must point at a backup folder or archive"
[ -f "$CLIENT_DIR/secrets.env" ] || die "Not provisioned yet. Run scripts/provision.sh first."

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# --- unpack an encrypted or plain archive into a private temporary folder ----------------------
if [ -f "$FROM" ]; then
  mkdir -p "$BACKUP_DIR"
  TMP="$(mktemp -d "$BACKUP_DIR/.restore-XXXXXX")"
  chmod 700 "$TMP"
  log "Unpacking $FROM"
  case "$FROM" in
    *.tar.age)
      command -v age >/dev/null 2>&1 || die "age is not installed"
      [ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ] && [ -f "$BACKUP_AGE_IDENTITY_FILE" ] || die "Set BACKUP_AGE_IDENTITY_FILE to the age private key file to decrypt $FROM"
      age -d -i "$BACKUP_AGE_IDENTITY_FILE" "$FROM" | tar -C "$TMP" -xf - || die "Could not decrypt $FROM"
      ;;
    *.tar.gpg)
      command -v gpg >/dev/null 2>&1 || die "gpg is not installed"
      if [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; then
        gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" --decrypt "$FROM" | tar -C "$TMP" -xf - || die "Could not decrypt $FROM"
      else
        gpg --batch --yes --decrypt "$FROM" | tar -C "$TMP" -xf - || die "Could not decrypt $FROM (is the secret key in this keyring?)"
      fi
      ;;
    *.tar) tar -C "$TMP" -xf "$FROM" || die "Could not unpack $FROM" ;;
    *) die "--from must be a backup folder, or a .tar.age, .tar.gpg or .tar archive" ;;
  esac
  inner="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$inner" ] || die "$FROM holds no backup folder"
  FROM="$inner"
fi

[ -d "$FROM" ] && [ -f "$FROM/database.dump" ] && [ -f "$FROM/files.tar.gz" ] && [ -f "$FROM/manifest.txt" ] || die "--from must point at a backup folder or archive"
if ! grep -q "^client=$CLIENT_SLUG$" "$FROM/manifest.txt"; then die "That backup belongs to a different company"; fi
(cd "$FROM" && grep -E '  (database.dump|files.tar.gz|config.tar.gz)$' manifest.txt | shasum -a 256 -c -) || die "Backup failed its checksum"
[ "$YES" = true ] || die "This overwrites all data for $CLIENT_SLUG. Re-run with --yes to confirm."

stamp="$(date +%Y%m%d%H%M%S)"
prev_db="lims_pre_restore_$stamp"
psql_owner() { compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres psql -U lims_owner -v ON_ERROR_STOP=1 -X -q "$@"; }

compose up -d --wait postgres redis minio

# --- 1. restore into a temporary database; the live one is untouched ---------------------------
log "Restoring the database into a temporary database"
psql_owner -d postgres -c "DROP DATABASE IF EXISTS lims_restore WITH (FORCE);" -c "CREATE DATABASE lims_restore OWNER lims_owner;" -c "GRANT CONNECT ON DATABASE lims_restore TO lims_app;" >/dev/null
# Default privileges are per database, so set them in the new one before restoring into it.
psql_owner -d lims_restore >/dev/null <<'SQL'
GRANT USAGE ON SCHEMA public TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO lims_app;
SQL
if ! compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres pg_restore -U lims_owner -d lims_restore --no-owner --role=lims_owner --exit-on-error < "$FROM/database.dump"; then
  psql_owner -d postgres -c "DROP DATABASE IF EXISTS lims_restore WITH (FORCE);" >/dev/null || true
  die "pg_restore failed. The live database was not touched."
fi

log "Checking the restored database"
migrations="$(psql_owner -d lims_restore -At -c 'SELECT count(*) FROM "_prisma_migrations" WHERE finished_at IS NOT NULL' 2>/dev/null || echo 0)"
tables="$(psql_owner -d lims_restore -At -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo 0)"
app_ok="$(compose exec -T -e PGPASSWORD="$POSTGRES_APP_PASSWORD" postgres psql -h localhost -U lims_app -d lims_restore -X -At -c 'SELECT count(*) FROM "_prisma_migrations"' 2>/dev/null || echo no)"
if [ "${migrations:-0}" -lt 1 ] || [ "${tables:-0}" -lt 2 ] || [ "$app_ok" = no ]; then
  psql_owner -d postgres -c "DROP DATABASE IF EXISTS lims_restore WITH (FORCE);" >/dev/null || true
  die "The restored database failed its checks (migrations=$migrations tables=$tables app-role-read=$app_ok). The live database was not touched."
fi
log "Restored database looks right: $tables tables, $migrations migrations"

# --- 2. stop the app and swap the databases -----------------------------------------------------
log "Stopping the app"
compose stop api worker ui
log "Swapping databases (the current one is kept as $prev_db until the app is healthy)"
psql_owner -d postgres >/dev/null <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('lims', 'lims_restore') AND pid <> pg_backend_pid();
BEGIN;
ALTER DATABASE lims RENAME TO $prev_db;
ALTER DATABASE lims_restore RENAME TO lims;
COMMIT;
SQL

swap_back_hint() {
  printf 'The database from before the restore is kept as %s. To put it back:\n' "$prev_db" >&2
  printf '  docker exec %s-postgres-1 psql -U lims_owner -d postgres -c "ALTER DATABASE lims RENAME TO lims_failed_%s" -c "ALTER DATABASE %s RENAME TO lims"\n' "$COMPOSE_PROJECT_NAME" "$stamp" "$prev_db" >&2
}

# --- 3. files: unpack beside the live ones, then swap -------------------------------------------
log "Restoring files"
compose stop minio
storage="$(compose ps -aq minio)"
if ! docker run --rm --volumes-from "$storage" -v "$FROM":/in:ro alpine:3 sh -euc '
  [ ! -e /data/.lims-restore-old ] || { echo "/data/.lims-restore-old exists from an earlier failed restore; inspect it first" >&2; exit 1; }
  rm -rf /data/.lims-restore-new
  mkdir /data/.lims-restore-new
  tar xzf /in/files.tar.gz -C /data/.lims-restore-new
  mkdir /data/.lims-restore-old
  find /data -mindepth 1 -maxdepth 1 ! -name .lims-restore-new ! -name .lims-restore-old -exec mv {} /data/.lims-restore-old/ \;
  find /data/.lims-restore-new -mindepth 1 -maxdepth 1 -exec mv {} /data/ \;
  rm -rf /data/.lims-restore-new /data/.lims-restore-old
'; then
  compose up -d minio || true
  swap_back_hint
  die "Restoring files failed. Stored files are unchanged unless the message above says otherwise."
fi
compose up -d --wait minio

# --- 4. migrations, then start ---------------------------------------------------------------
log "Running migrations on the restored database"
write_generated_env
compose run --rm migrate || { swap_back_hint; die "Migrations failed on the restored database. The app is stopped."; }

log "Restarting"
compose up -d api worker ui
wait_healthy || { compose logs --tail 40 api >&2; swap_back_hint; die "The API did not become healthy after restore"; }

if [ "$KEEP_PREVIOUS" = true ]; then
  log "Kept the previous database as $prev_db. Drop it when satisfied: docker exec $COMPOSE_PROJECT_NAME-postgres-1 psql -U lims_owner -d postgres -c 'DROP DATABASE $prev_db'"
else
  psql_owner -d postgres -c "DROP DATABASE IF EXISTS $prev_db WITH (FORCE);" >/dev/null || log "Could not drop $prev_db; drop it by hand"
fi
log "Restore complete from $FROM"
