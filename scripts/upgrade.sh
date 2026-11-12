#!/usr/bin/env bash
# Moves one company to new image versions, backing up first and rolling back if it won't start:
#   scripts/upgrade.sh --client-dir /srv/lims-clients/acme --lims 0.2.0 --ui 0.2.0
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
NEW_LIMS=""; NEW_UI=""
set -- ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
while [ $# -gt 0 ]; do
  case "$1" in
    --lims) NEW_LIMS="${2:-}"; shift 2 ;;
    --ui) NEW_UI="${2:-}"; shift 2 ;;
    *) die "Unknown option $1" ;;
  esac
done
[ -n "$NEW_LIMS" ] || [ -n "$NEW_UI" ] || die "Say which versions: --lims X --ui Y"
OLD_LIMS="$LIMS_VERSION"; OLD_UI="$LIMS_UI_VERSION"
NEW_LIMS="${NEW_LIMS:-$OLD_LIMS}"; NEW_UI="${NEW_UI:-$OLD_UI}"

# Pull first: a mistyped or missing tag should fail before the backup and the downtime.
for img in "ghcr.io/avaniecocare/lims:$NEW_LIMS" "ghcr.io/avaniecocare/lims-ui:$NEW_UI"; do
  docker image inspect "$img" >/dev/null 2>&1 && continue
  log "Pulling $img"
  docker pull -q "$img" >/dev/null || die "Cannot pull $img. Check the version and the registry login. Nothing was changed."
done

log "Backing up before upgrade"
# --keep-plaintext: an automatic rollback must work even when the decryption key is off the server.
# --local-only: no off-site copy or ping for this one; the nightly backup does those.
backup_path="$("$DEPLOY_ROOT/scripts/backup.sh" --client-dir "$CLIENT_DIR" --keep-plaintext --local-only | tail -1)" || die "The pre-upgrade backup failed. Nothing was changed."
[ -d "$backup_path" ] || die "The pre-upgrade backup did not produce a folder ($backup_path). Nothing was changed."

# History lets rollback.sh find the previous versions and the backup taken just before.
printf '%s lims=%s ui=%s backup=%s\n' "$(date -u +%FT%TZ)" "$OLD_LIMS" "$OLD_UI" "$backup_path" >> "$CLIENT_DIR/versions.history"
cat > "$CLIENT_DIR/versions.env" <<EOF
LIMS_VERSION="$NEW_LIMS"
LIMS_UI_VERSION="$NEW_UI"
EOF

log "Upgrading $CLIENT_SLUG to $NEW_LIMS / $NEW_UI"
if ! "$DEPLOY_ROOT/scripts/deploy.sh" --client-dir "$CLIENT_DIR"; then
  log "Upgrade failed. Rolling back."
  "$DEPLOY_ROOT/scripts/rollback.sh" --client-dir "$CLIENT_DIR" --yes
  die "Upgrade to $NEW_LIMS / $NEW_UI failed and was rolled back"
fi
log "Upgraded."
