#!/usr/bin/env bash
# Shows what one company is running: scripts/status.sh --client-dir /srv/lims-clients/acme
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
echo "$CLIENT_SLUG: lims $LIMS_VERSION, ui $LIMS_UI_VERSION"
compose ps
