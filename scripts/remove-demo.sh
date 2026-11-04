#!/usr/bin/env bash
# Removes all demo data from one company in one command:
#   scripts/remove-demo.sh --client-dir /srv/lims-clients/acme --yes
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
YES=false
for a in "${EXTRA_ARGS[@]:-}"; do [ "$a" = "--yes" ] && YES=true; done
[ "$YES" = true ] || die "This deletes all demo data for $CLIENT_SLUG. Re-run with --yes."
owner_url="$(grep '^MIGRATION_DATABASE_URL=' "$CLIENT_DIR/generated.env" | cut -d= -f2- | tr -d '"')"
compose exec -T -e DATABASE_URL="$owner_url" api node dist/seed/cli.js remove
log "Demo data removed from $CLIENT_SLUG"
