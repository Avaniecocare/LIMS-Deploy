#!/bin/sh
# Starts the app with the secrets this installation made. Only `migrate` gets the table owner's password.
set -eu
s() { cat "/run/lims/$1"; }
# Assigned before being exported, so a missing secret stops here.
SESSION_SECRET="$(s session-secret)"
SETUP_TOKEN="$(s setup-token)"
REDIS_URL="redis://:$(s redis-password)@redis:6379/0"
S3_ACCESS_KEY="$(s s3-access-key)"
S3_SECRET_KEY="$(s s3-secret-key)"
DATABASE_URL="postgresql://lims_app:$(s app-password)@postgres:5432/lims"
[ "${1:-}" != migrate ] || DATABASE_URL="postgresql://lims_owner:$(s owner-password)@postgres:5432/lims"
export SESSION_SECRET SETUP_TOKEN REDIS_URL S3_ACCESS_KEY S3_SECRET_KEY DATABASE_URL
case "${1:-}" in
  migrate) exec node_modules/.bin/prisma migrate deploy ;;
  api | worker) exec node dist/main.js "$1" ;;
  *) exec "$@" ;;
esac
