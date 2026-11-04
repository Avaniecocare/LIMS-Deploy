#!/usr/bin/env bash
# Returns one company to the versions before its last upgrade. Migrations only go forward, so this
# also restores the backup taken just before that upgrade. Work done since then is lost.
#   scripts/rollback.sh --client-dir /srv/lims-clients/acme --yes
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
YES=false
for a in "${EXTRA_ARGS[@]:-}"; do [ "$a" = "--yes" ] && YES=true; done
[ -f "$CLIENT_DIR/versions.history" ] || die "No upgrade history for $CLIENT_SLUG"
last="$(tail -1 "$CLIENT_DIR/versions.history")"
prev_lims="$(sed -E 's/.* lims=([^ ]+).*/\1/' <<<"$last")"
prev_ui="$(sed -E 's/.* ui=([^ ]+).*/\1/' <<<"$last")"
backup="$(sed -E 's/.* backup=(.*)/\1/' <<<"$last")"
[ "$YES" = true ] || die "This returns $CLIENT_SLUG to $prev_lims / $prev_ui and restores $backup, losing work since. Re-run with --yes."

cat > "$CLIENT_DIR/versions.env" <<EOF
LIMS_VERSION="$prev_lims"
LIMS_UI_VERSION="$prev_ui"
EOF
load_client
"$DEPLOY_ROOT/scripts/restore.sh" --client-dir "$CLIENT_DIR" --from "$backup" --yes
sed -i.bak '$d' "$CLIENT_DIR/versions.history" && rm -f "$CLIENT_DIR/versions.history.bak"
log "Rolled back to $prev_lims / $prev_ui"
