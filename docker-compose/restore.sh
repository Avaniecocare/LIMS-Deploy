#!/bin/sh
# Replaces ALL data in this installation with a backup. Run it from this folder:
#   ./restore.sh backups/<time> --yes
# The secrets come back with it, so this also works on a new machine: copy this folder and the backup there first.
set -eu
cd "$(dirname "$0")"
from="${1:-}"
[ "${2:-}" = --yes ] || { echo "This replaces all data in this installation. Usage: ./restore.sh backups/<time> --yes" >&2; exit 64; }
for f in database.dump files.tar.gz secrets.tar.gz; do [ -s "$from/$f" ] || { echo "$from/$f is missing or empty" >&2; exit 1; }; done
[ -f .env ] || cp "$from/env" .env
# Checked before anything is touched.
docker compose run --rm -T --no-deps --entrypoint pg_restore postgres --list < "$from/database.dump" > /dev/null
gzip -t "$from/files.tar.gz"
gzip -t "$from/secrets.tar.gz"
docker compose down
project="$(docker compose config --format json | sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1)"
[ -n "$project" ] || project=lims-trial
# The old data is kept aside until the restored installation is running.
stamp="$(date -u +%Y%m%d%H%M%S)"
for v in secrets pgdata files; do
  if docker volume inspect "${project}_$v" > /dev/null 2>&1; then
    docker volume create "${project}_$v-before-$stamp" > /dev/null
    docker run --rm -v "${project}_$v:/from:ro" -v "${project}_$v-before-$stamp:/to" postgres:18-alpine sh -c 'cp -a /from/. /to/'
    docker volume rm "${project}_$v" > /dev/null
  fi
done
# Queued jobs and sessions belong to the data being replaced.
docker volume rm "${project}_redisdata" > /dev/null 2>&1 || true
docker compose run --rm -T --no-deps --entrypoint tar secrets xzf - -C /run/lims < "$from/secrets.tar.gz"
docker compose run --rm -T --no-deps --entrypoint sh storage -c 'tar xzf - -C /data' < "$from/files.tar.gz"
docker compose up -d --wait postgres
docker compose exec -T postgres pg_restore -U lims_owner -d lims --no-owner --role=lims_owner --exit-on-error < "$from/database.dump"
docker compose up -d --wait
echo "Restored. Once you have checked it, remove the old data with:"
for v in secrets pgdata files; do echo "  docker volume rm ${project}_$v-before-$stamp"; done
