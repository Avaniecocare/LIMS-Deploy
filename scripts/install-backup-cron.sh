#!/usr/bin/env bash
# Installs a nightly backup for one company (02:00 server time) in the current user's crontab:
#   scripts/install-backup-cron.sh --client-dir /srv/lims-clients/acme
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
line="0 2 * * * $DEPLOY_ROOT/scripts/backup.sh --client-dir $CLIENT_DIR >> $CLIENT_DIR/backup.log 2>&1 # lims-backup-$CLIENT_SLUG"
if crontab -l 2>/dev/null | grep -q "lims-backup-$CLIENT_SLUG"; then
  log "Nightly backup already installed for $CLIENT_SLUG"
  exit 0
fi
for a in "${EXTRA_ARGS[@]:-}"; do
  if [ "$a" = "--check-only" ]; then
    log "No nightly backup yet. Run scripts/install-backup-cron.sh --client-dir $CLIENT_DIR"
    exit 0
  fi
done
(crontab -l 2>/dev/null; echo "$line") | crontab -
log "Nightly backup installed for $CLIENT_SLUG"
