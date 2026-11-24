#!/usr/bin/env bash
# Applies the current deployment.env and versions.env (server settings and versions). The lab's details and
# branding are changed in the app (Admin > Lab profile, Branding), with no deploy needed.
#   scripts/deploy.sh --client-dir /srv/lims-clients/acme
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
[ -f "$CLIENT_DIR/secrets.env" ] || die "Not provisioned yet. Run scripts/provision.sh first."
write_generated_env
# The domains may have changed.
"$DEPLOY_ROOT/scripts/proxy-sync.sh" --client-dir "$CLIENT_DIR"
prepare_storage
compose up -d --wait postgres redis minio
compose run --rm migrate
compose up -d --force-recreate api worker ui
wait_healthy || { compose logs --tail 40 api >&2; die "The API did not become healthy. Check the settings named in the log."; }
log "$CLIENT_SLUG is running ${LIMS_VERSION} / ${LIMS_UI_VERSION}"
