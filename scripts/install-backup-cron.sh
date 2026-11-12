#!/usr/bin/env bash
# Installs a nightly backup for one company (02:00 server time) in the current user's crontab:
#   scripts/install-backup-cron.sh --client-dir /srv/lims-clients/acme [--check-only]
# provision.sh runs this. Safe to re-run: it replaces this company's line, never duplicates it.
# The user must be able to run docker (docker group). Output goes to <client-dir>/backup.log;
# backup.sh exits non-zero and prints "BACKUP FAILED" when anything goes wrong.
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
CHECK_ONLY=false
for a in "${EXTRA_ARGS[@]:-}"; do
  case "$a" in
    --check-only) CHECK_ONLY=true ;;
    "") ;;
    *) die "Unknown option $a" ;;
  esac
done
marker="# lims-backup-$CLIENT_SLUG"

if [ "$CHECK_ONLY" = true ]; then
  if crontab -l 2>/dev/null | grep -qF "$marker"; then
    log "Nightly backup is installed for $CLIENT_SLUG"
    exit 0
  fi
  die "No nightly backup for $CLIENT_SLUG. Run scripts/install-backup-cron.sh --client-dir $CLIENT_DIR"
fi

command -v crontab >/dev/null 2>&1 || die "crontab is not installed. Install cron (e.g. apt-get install cron), then re-run."
docker info >/dev/null 2>&1 || die "$(id -un) cannot run docker, so a nightly backup from this crontab would fail. Add the user to the docker group or install from a user who can."

q() { printf '%q' "$1"; }
# cron runs with a minimal PATH; set one that finds docker, age, gpg, rclone and aws.
line="0 2 * * * env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $(q "$DEPLOY_ROOT/scripts/backup.sh") --client-dir $(q "$CLIENT_DIR") >> $(q "$CLIENT_DIR/backup.log") 2>&1 $marker"

current="$(crontab -l 2>/dev/null || true)"
if grep -qxF "$line" <<<"$current"; then
  log "Nightly backup already installed for $CLIENT_SLUG"
  exit 0
fi
{ grep -vF "$marker" <<<"$current" || true; echo "$line"; } | sed '/^$/d' | crontab -
crontab -l 2>/dev/null | grep -qxF "$line" || die "The crontab did not take the backup line for $CLIENT_SLUG"
log "Nightly backup installed for $CLIENT_SLUG (02:00, log: $CLIENT_DIR/backup.log)"
