#!/usr/bin/env bash
# Runs pending database migrations for one company:
#   scripts/migrate.sh --client-dir /srv/lims-clients/acme
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
[ -f "$CLIENT_DIR/secrets.env" ] || die "Not provisioned yet. Run scripts/provision.sh first."
write_generated_env
compose run --rm migrate
log "Migrations applied for $CLIENT_SLUG"
