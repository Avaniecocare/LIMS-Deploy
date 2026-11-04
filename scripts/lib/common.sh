#!/usr/bin/env bash
# Shared by every script. Company files live OUTSIDE this repository; --client-dir says where.
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DEPLOY_ROOT

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

CLIENT_DIR=""
EXTRA_ARGS=()
parse_client_dir() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --client-dir) CLIENT_DIR="${2:-}"; shift 2 ;;
      *) EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
  [ -n "$CLIENT_DIR" ] || die "--client-dir PATH is required (the company's folder, outside this repository)"
  [ -d "$CLIENT_DIR" ] || die "No such folder: $CLIENT_DIR"
  CLIENT_DIR="$(cd "$CLIENT_DIR" && pwd)"
  case "$CLIENT_DIR/" in
    "$DEPLOY_ROOT"/clients/example-*) ;;
    "$DEPLOY_ROOT"/*) die "Company files must stay outside this public repository. Move them, then pass that path." ;;
  esac
  export CLIENT_DIR
}

require_file() { [ -f "$1" ] || die "Missing $1"; }

load_client() {
  for f in company.env deployment.env versions.env; do require_file "$CLIENT_DIR/$f"; done
  set -a
  # shellcheck disable=SC1091
  . "$CLIENT_DIR/deployment.env"
  # shellcheck disable=SC1091
  . "$CLIENT_DIR/versions.env"
  [ -f "$CLIENT_DIR/secrets.env" ] && . "$CLIENT_DIR/secrets.env"
  set +a
  [[ "${CLIENT_SLUG:-}" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "CLIENT_SLUG must be lowercase letters, digits and hyphens"
  export COMPOSE_PROJECT_NAME="lims-$CLIENT_SLUG"
  export COMPOSE_FILE="$DEPLOY_ROOT/compose/docker-compose.yml"
  [ -n "${S3_IMAGE:-}" ] || die "Set S3_IMAGE in $CLIENT_DIR/deployment.env (see DECISIONS.md)"
  BACKUP_DIR="${LIMS_BACKUP_DIR:-$CLIENT_DIR/backups}"
  export BACKUP_DIR
}

compose() { docker compose --env-file "$CLIENT_DIR/secrets.env" --env-file "$CLIENT_DIR/versions.env" --env-file "$CLIENT_DIR/deployment.env" "$@"; }

random_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

# Everything the app needs that is not COMPANY_*, derived from deployment.env and secrets.env.
write_generated_env() {
  local out="$CLIENT_DIR/generated.env"
  umask 077
  cat > "$out" <<EOF
NODE_ENV="production"
PORT="3000"
TRUST_PROXY="true"
COOKIE_SECURE="true"
DATABASE_URL="postgresql://lims_app:${POSTGRES_APP_PASSWORD}@postgres:5432/lims"
MIGRATION_DATABASE_URL="postgresql://lims_owner:${POSTGRES_OWNER_PASSWORD}@postgres:5432/lims"
DATABASE_READ_URL="${DATABASE_READ_URL:-}"
REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379/0"
SESSION_SECRET="${SESSION_SECRET}"
SETUP_TOKEN="${SETUP_TOKEN}"
FRONTEND_ORIGIN="https://${APP_DOMAIN}"
PUBLIC_API_URL="https://${API_DOMAIN}"
S3_ENDPOINT="http://minio:9000"
S3_PUBLIC_ENDPOINT="https://${FILES_DOMAIN}"
S3_BUCKET="lims"
S3_ACCESS_KEY="${S3_ACCESS_KEY}"
S3_SECRET_KEY="${S3_SECRET_KEY}"
SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_SECURE="${SMTP_SECURE}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM}"
ERROR_TRACKING_DSN="${ERROR_TRACKING_DSN:-}"
EOF
  chmod 600 "$out"
}

wait_healthy() {
  local tries="${1:-60}"
  for _ in $(seq 1 "$tries"); do
    if compose exec -T api node -e "fetch('http://localhost:3000/health/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}
