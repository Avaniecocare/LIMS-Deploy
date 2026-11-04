#!/usr/bin/env bash
# Applies the current company.env and versions.env. Use after changing company details:
#   scripts/deploy.sh --client-dir /srv/lims-clients/acme
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
[ -f "$CLIENT_DIR/secrets.env" ] || die "Not provisioned yet. Run scripts/provision.sh first."
write_generated_env
compose up -d --wait postgres redis minio
compose run --rm migrate
compose up -d --force-recreate api worker ui
wait_healthy || { compose logs --tail 40 api >&2; die "The API did not become healthy. Check the company.env values named in the log."; }
log "$CLIENT_SLUG is running ${LIMS_VERSION} / ${LIMS_UI_VERSION}"
