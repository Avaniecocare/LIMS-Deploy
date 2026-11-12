#!/usr/bin/env bash
# Removes all demo data from one company in one command:
#   scripts/remove-demo.sh --client-dir /srv/lims-clients/acme --yes
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
YES=false
for a in "${EXTRA_ARGS[@]:-}"; do [ "$a" = "--yes" ] && YES=true; done
[ "$YES" = true ] || die "This deletes all demo data for $CLIENT_SLUG. Re-run with --yes."
run_as_owner node dist/seed/cli.js remove
log "Demo data removed from $CLIENT_SLUG"
