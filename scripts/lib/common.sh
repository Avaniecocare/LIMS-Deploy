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
  # company.env is optional: new installs set the lab up in the app; older ones are imported from it once.
  for f in deployment.env versions.env; do require_file "$CLIENT_DIR/$f"; done
  mkdir -p "$CLIENT_DIR/branding"
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
  # Folders provisioned before the owner credentials moved to migrate.env: split them now, so
  # compose finds migrate.env and generated.env stops carrying the owner password.
  if [ -f "$CLIENT_DIR/secrets.env" ] && { [ ! -f "$CLIENT_DIR/migrate.env" ] || grep -q '^MIGRATION_DATABASE_URL=' "$CLIENT_DIR/generated.env" 2>/dev/null; }; then
    write_generated_env
  fi
}

compose() { docker compose --env-file "$CLIENT_DIR/secrets.env" --env-file "$CLIENT_DIR/versions.env" --env-file "$CLIENT_DIR/deployment.env" "$@"; }

random_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

# Everything the app needs, derived from deployment.env and secrets.env. The lab's own details are not here:
# the administrator sets them in the app after the first sign-in.
# generated.env goes to the api and worker, so it carries only the lims_app role. The owner
# credentials go to migrate.env, which only the migrate service loads (see compose).
write_generated_env() {
  local out="$CLIENT_DIR/generated.env"
  umask 077
  cat > "$out" <<EOF
BRAND_NAME="${BRAND_NAME:-LIMS}"
NODE_ENV="production"
PORT="3000"
TRUST_PROXY="true"
COOKIE_SECURE="true"
DATABASE_URL="postgresql://lims_app:${POSTGRES_APP_PASSWORD}@postgres:5432/lims"
DATABASE_READ_URL="${DATABASE_READ_URL:-}"
REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379/0"
SESSION_SECRET="${SESSION_SECRET}"
SETUP_TOKEN="${SETUP_TOKEN}"
FRONTEND_ORIGIN="https://${APP_DOMAIN}"
PUBLIC_API_URL="https://${API_DOMAIN}"
S3_ENDPOINT="http://lims-${CLIENT_SLUG}-storage:9000"
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
SMTP_TRANSPORT="${SMTP_TRANSPORT:-smtp}"
ERROR_TRACKING_DSN="${ERROR_TRACKING_DSN:-}"
WHATSAPP_TOKEN="${WHATSAPP_TOKEN:-}"
WHATSAPP_PHONE_NUMBER_ID="${WHATSAPP_PHONE_NUMBER_ID:-}"
WHATSAPP_APP_SECRET="${WHATSAPP_APP_SECRET:-}"
WHATSAPP_VERIFY_TOKEN="${WHATSAPP_VERIFY_TOKEN:-}"
ENABLE_AI_ASSISTANT="${ENABLE_AI_ASSISTANT:-}"
AI_PROVIDER="${AI_PROVIDER:-}"
AI_API_KEY="${AI_API_KEY:-}"
AI_MODEL="${AI_MODEL:-}"
EMBEDDING_PROVIDER="${EMBEDDING_PROVIDER:-}"
EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"
HELP_INDEX_URL="${HELP_INDEX_URL:-}"
RATE_LIMIT_PER_MINUTE="${RATE_LIMIT_PER_MINUTE:-}"
RATE_LIMIT_PER_DAY="${RATE_LIMIT_PER_DAY:-}"
SIGNED_IN_RATE_LIMIT_PER_DAY="${SIGNED_IN_RATE_LIMIT_PER_DAY:-}"
DAILY_BUDGET_LIMIT="${DAILY_BUDGET_LIMIT:-}"
MONTHLY_BUDGET_LIMIT="${MONTHLY_BUDGET_LIMIT:-}"
MAX_QUESTION_LENGTH="${MAX_QUESTION_LENGTH:-}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-}"
TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:-}"
TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET_KEY:-}"
AI_REQUIRE_LOGIN="${AI_REQUIRE_LOGIN:-}"
ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-}"
HELP_SUPPORT_EMAIL="${HELP_SUPPORT_EMAIL:-}"
HELP_LOG_RETENTION_DAYS="${HELP_LOG_RETENTION_DAYS:-}"
SESSION_MAX_HOURS="${SESSION_MAX_HOURS:-12}"
PINCODE_LOOKUP_URL="${PINCODE_LOOKUP_URL-https://api.postalpincode.in/pincode/}"
EOF
  chmod 600 "$out"
  write_migrate_env
}

# Table-owner credentials, for the migrate service and owner-level one-off tasks only.
write_migrate_env() {
  local out="$CLIENT_DIR/migrate.env"
  umask 077
  printf 'MIGRATION_DATABASE_URL="postgresql://lims_owner:%s@postgres:5432/lims"\n' "$POSTGRES_OWNER_PASSWORD" > "$out"
  chmod 600 "$out"
}

# Runs a one-off command in a throwaway migrate container, connected as the table owner.
# The api and worker never hold these credentials.
run_as_owner() {
  # shellcheck disable=SC2016 # expanded inside the container, not here
  compose run --rm -T migrate sh -c 'DATABASE_URL="$MIGRATION_DATABASE_URL" exec "$@"' sh "$@"
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
