#!/usr/bin/env bash
# Adds a company from a filled-in folder, with no code changes:
#   scripts/provision.sh --client-dir /srv/lims-clients/acme [--with-demo-data] [--offline]
# Creates secrets, starts its own database, cache and storage, migrates, starts the app and
# installs the nightly backup (LIMS_SKIP_BACKUP_CRON=true skips that, for throwaway checks only).
# Safe to re-run: existing secrets are kept.
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
WITH_DEMO=false
OFFLINE=false
for a in "${EXTRA_ARGS[@]:-}"; do
  case "$a" in
    --with-demo-data) WITH_DEMO=true ;;
    --offline) OFFLINE=true ;;
    "") ;;
    *) die "Unknown option $a" ;;
  esac
done
load_client

if [ ! -f "$CLIENT_DIR/secrets.env" ]; then
  log "Generating secrets for $CLIENT_SLUG"
  umask 077
  cat > "$CLIENT_DIR/secrets.env" <<EOF
POSTGRES_OWNER_PASSWORD="$(random_secret)"
POSTGRES_APP_PASSWORD="$(random_secret)"
REDIS_PASSWORD="$(random_secret)"
S3_ACCESS_KEY="${LIMS_S3_ACCESS_KEY:-$(random_secret 20)}"
S3_SECRET_KEY="${LIMS_S3_SECRET_KEY:-$(random_secret)}"
SESSION_SECRET="$(random_secret 64)"
SETUP_TOKEN="$(random_secret 32)"
EOF
  chmod 600 "$CLIENT_DIR/secrets.env"
fi
load_client
write_generated_env

docker network inspect lims-proxy >/dev/null 2>&1 || docker network create lims-proxy >/dev/null
"$DEPLOY_ROOT/scripts/proxy-sync.sh" --client-dir "$CLIENT_DIR"

log "Starting $CLIENT_SLUG (images ${LIMS_VERSION} / ${LIMS_UI_VERSION})"
if [ "$OFFLINE" = true ]; then
  log "Offline: using local images"
else
  compose pull --quiet --policy missing || die "Could not pull the images. Check versions.env and the registry login (docker login ghcr.io), or pass --offline to use local images."
fi
compose up -d --wait postgres redis minio
compose run --rm migrate
compose up -d api worker ui
wait_healthy || { compose logs --tail 40 api >&2; die "The API did not become healthy"; }

if [ "$WITH_DEMO" = true ]; then
  log "Loading demo data, as requested"
  run_as_owner node dist/seed/cli.js seed
fi

if [ "${LIMS_SKIP_BACKUP_CRON:-false}" = true ]; then
  log "Nightly backup NOT installed (LIMS_SKIP_BACKUP_CRON=true). Run scripts/install-backup-cron.sh before real data goes in."
else
  "$DEPLOY_ROOT/scripts/install-backup-cron.sh" --client-dir "$CLIENT_DIR" || die "Could not install the nightly backup. Fix that (see above) and re-run provision.sh; it is safe to re-run."
fi
log "Provisioned. Open https://$APP_DOMAIN"
[ "$WITH_DEMO" = true ] || log "First-run setup token: stored in $CLIENT_DIR/secrets.env as SETUP_TOKEN"
