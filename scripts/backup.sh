#!/usr/bin/env bash
# Backs up one company: database, stored files, and the company folder's own settings.
#   scripts/backup.sh --client-dir /srv/lims-clients/acme [--keep-plaintext] [--local-only]
#
# Writes into BACKUP_DIR (default <client-dir>/backups) a folder <timestamp>/ holding
#   database.dump    pg_dump custom format, checked with pg_restore --list
#   files.tar.gz     the object store's /data
#   config.tar.gz    company.env, deployment.env, secrets.env, versions.env, versions.history
#                    and branding/ (what a new server needs to bring the company back)
#   manifest.txt     company, versions and SHA-256 checksums
#
# Encryption (deployment.env; see DEPLOYMENT.md "Backups"). When one is set, the folder is packed
# into <timestamp>.tar.age or <timestamp>.tar.gpg and the plain folder is removed, unless
# --keep-plaintext is given (upgrade.sh does, so a rollback works without the private key).
#   BACKUP_AGE_RECIPIENT="age1..."           one or more age public keys, space-separated
#   BACKUP_GPG_RECIPIENT="ops@example.com"   a public key in this user's gpg keyring
#   BACKUP_GPG_PASSPHRASE_FILE="/path"       symmetric gpg, passphrase read from that file
# Off-site copy, run after the backup with BACKUP_FILE set to the encrypted archive:
#   BACKUP_OFFSITE_CMD='rclone copy "$BACKUP_FILE" offsite:lims-backups/$CLIENT_SLUG/'
# An off-site copy of an unencrypted backup is refused unless BACKUP_OFFSITE_ALLOW_PLAINTEXT=true.
# Optional BACKUP_PING_URL is fetched after a fully successful run (a dead-man's switch).
# --local-only skips the off-site copy and the ping (upgrade.sh uses it for its own backup).
# Local backups older than BACKUP_RETENTION_DAYS (default 30) are deleted after a good backup.
#
# Exit status is non-zero, with a "BACKUP FAILED" line on stderr, if any step fails. The last
# line of stdout is the path of the backup (the folder, or the archive when the folder is removed).
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
stamp="$(date +%Y%m%d-%H%M%S)"
dest="$BACKUP_DIR/$stamp"
archive=""
step="checking settings"
local_done=false
all_done=false
on_exit() {
  local rc=$?
  [ "$all_done" = true ] && return
  [ "$rc" -eq 0 ] && rc=1
  printf '[%s] BACKUP FAILED for %s at step "%s" (exit %s). ' "$(date '+%F %T')" "${CLIENT_SLUG:-?}" "$step" "$rc" >&2
  if [ "$local_done" = true ]; then
    printf 'The local backup is complete: %s\n' "${archive:-$dest}" >&2
  else
    printf 'Nothing usable was written; the partial backup was removed.\n' >&2
    rm -rf "$dest"
    [ -n "$archive" ] && rm -f "$archive" "$archive.part"
  fi
  exit "$rc"
}
trap on_exit EXIT

KEEP_PLAIN=false
LOCAL_ONLY=false
for a in "${EXTRA_ARGS[@]:-}"; do
  case "$a" in
    --keep-plaintext) KEEP_PLAIN=true ;;
    --local-only) LOCAL_ONLY=true ;;
    "") ;;
    *) die "Unknown option $a" ;;
  esac
done
[ -f "$CLIENT_DIR/secrets.env" ] || die "Not provisioned yet: no secrets.env in $CLIENT_DIR"
RETENTION="${BACKUP_RETENTION_DAYS:-30}"
[[ "$RETENTION" =~ ^[0-9]+$ ]] && [ "$RETENTION" -ge 1 ] || die "BACKUP_RETENTION_DAYS must be a whole number of days, 1 or more"

# Keep the cron log from growing for ever.
if [ -f "$CLIENT_DIR/backup.log" ] && [ "$(wc -c < "$CLIENT_DIR/backup.log")" -gt 5242880 ]; then
  mv -f "$CLIENT_DIR/backup.log" "$CLIENT_DIR/backup.log.1"
fi

# --- choose encryption before doing any work, so a missing tool fails fast ---------------------
ENC=""
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  ENC=age
  command -v age >/dev/null 2>&1 || die "BACKUP_AGE_RECIPIENT is set but age is not installed (apt-get install age)"
elif [ -n "${BACKUP_GPG_RECIPIENT:-}" ]; then
  ENC=gpg
  command -v gpg >/dev/null 2>&1 || die "BACKUP_GPG_RECIPIENT is set but gpg is not installed"
  gpg --batch --list-keys "$BACKUP_GPG_RECIPIENT" >/dev/null 2>&1 || die "No gpg public key for $BACKUP_GPG_RECIPIENT in $(id -un)'s keyring"
elif [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; then
  ENC=gpg-symmetric
  command -v gpg >/dev/null 2>&1 || die "BACKUP_GPG_PASSPHRASE_FILE is set but gpg is not installed"
  [ -s "$BACKUP_GPG_PASSPHRASE_FILE" ] || die "BACKUP_GPG_PASSPHRASE_FILE ($BACKUP_GPG_PASSPHRASE_FILE) is missing or empty"
fi
if [ "$LOCAL_ONLY" = true ]; then BACKUP_OFFSITE_CMD=""; BACKUP_PING_URL=""; fi
if [ -n "${BACKUP_OFFSITE_CMD:-}" ] && [ -z "$ENC" ] && [ "${BACKUP_OFFSITE_ALLOW_PLAINTEXT:-false}" != true ]; then
  die "BACKUP_OFFSITE_CMD is set but backups are not encrypted. Set BACKUP_AGE_RECIPIENT (or a gpg option), or BACKUP_OFFSITE_ALLOW_PLAINTEXT=true to accept plain copies off the server."
fi


umask 077
mkdir -p "$BACKUP_DIR" "$dest"
chmod 700 "$BACKUP_DIR" "$dest"

step="database dump"
log "Dumping database"
compose exec -T -e PGPASSWORD="$POSTGRES_OWNER_PASSWORD" postgres pg_dump -U lims_owner -d lims -Fc > "$dest/database.dump"
[ -s "$dest/database.dump" ] || die "Database dump is empty"
step="database dump check"
compose exec -T postgres pg_restore --list < "$dest/database.dump" > /dev/null || die "pg_restore cannot read the dump"

step="stored files"
log "Archiving stored files"
storage="$(compose ps -q minio)"
[ -n "$storage" ] || die "The storage container is not running"
docker run --rm --volumes-from "$storage" -v "$dest":/out alpine:3 tar czf /out/files.tar.gz -C /data .
[ -s "$dest/files.tar.gz" ] || die "Files archive is empty"

step="company settings"
log "Archiving company settings"
cfg=(deployment.env secrets.env versions.env)
# The lab profile and branding are in the database dump; these older files go along when they exist.
for f in company.env branding versions.history migrate.env; do [ -e "$CLIENT_DIR/$f" ] && cfg+=("$f"); done
tar -C "$CLIENT_DIR" -czf "$dest/config.tar.gz" "${cfg[@]}"

step="manifest"
{
  echo "client=$CLIENT_SLUG"
  echo "created=$(date -u +%FT%TZ)"
  echo "lims=$LIMS_VERSION"
  echo "lims_ui=$LIMS_UI_VERSION"
  (cd "$dest" && sha256 database.dump files.tar.gz config.tar.gz)
} > "$dest/manifest.txt"
result="$dest"

if [ -n "$ENC" ]; then
  step="encryption ($ENC)"
  log "Encrypting with $ENC"
  case "$ENC" in
    age)
      archive="$BACKUP_DIR/$stamp.tar.age"
      args=()
      for r in $BACKUP_AGE_RECIPIENT; do args+=(-r "$r"); done
      tar -C "$BACKUP_DIR" -cf - "$stamp" | age "${args[@]}" -o "$archive.part"
      ;;
    gpg)
      archive="$BACKUP_DIR/$stamp.tar.gpg"
      tar -C "$BACKUP_DIR" -cf - "$stamp" | gpg --batch --yes --trust-model always --encrypt --recipient "$BACKUP_GPG_RECIPIENT" --output "$archive.part"
      ;;
    gpg-symmetric)
      archive="$BACKUP_DIR/$stamp.tar.gpg"
      tar -C "$BACKUP_DIR" -cf - "$stamp" | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" --symmetric --cipher-algo AES256 --output "$archive.part"
      ;;
  esac
  [ -s "$archive.part" ] || die "Encrypted archive is empty"
  mv "$archive.part" "$archive"
  if [ "$KEEP_PLAIN" = true ]; then
    log "Keeping the plain folder too (--keep-plaintext)"
  else
    rm -rf "$dest"
    result="$archive"
  fi
fi
local_done=true
log "Backup written to $result"

step="retention"
# Only timestamped backups made by this script are pruned, never anything else in BACKUP_DIR.
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -name '[0-9]*-[0-9]*' -mtime +"$RETENTION" -exec rm -rf {} +

if [ -n "${BACKUP_OFFSITE_CMD:-}" ]; then
  step="off-site copy"
  upload="$archive"
  if [ -z "$upload" ]; then
    upload="$BACKUP_DIR/$stamp.tar"
    tar -C "$BACKUP_DIR" -cf "$upload" "$stamp"
  fi
  log "Copying off-site"
  BACKUP_FILE="$upload" BACKUP_NAME="$(basename "$upload")" CLIENT_SLUG="$CLIENT_SLUG" sh -c "$BACKUP_OFFSITE_CMD" \
    || die "Off-site copy failed (BACKUP_OFFSITE_CMD exited non-zero)"
  [ "$upload" = "$archive" ] || rm -f "$upload"
  log "Off-site copy done"
fi

if [ -n "${BACKUP_PING_URL:-}" ]; then
  step="success ping"
  curl -fsS -m 10 --retry 3 "$BACKUP_PING_URL" > /dev/null || die "Backup succeeded but BACKUP_PING_URL did not answer"
fi

all_done=true
echo "$result"
