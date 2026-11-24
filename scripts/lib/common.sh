#!/usr/bin/env bash
# Shared by every script. Company files live OUTSIDE this repository; --client-dir says where.
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DEPLOY_ROOT

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Linux has sha256sum and macOS has shasum; some have both, and Amazon Linux only the first. Same output and --check.
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

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
  # shellcheck disable=SC1091
  [ -f "$CLIENT_DIR/secrets.env" ] && . "$CLIENT_DIR/secrets.env"
  set +a
  [[ "${CLIENT_SLUG:-}" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "CLIENT_SLUG must be lowercase letters, digits and hyphens"
  export COMPOSE_PROJECT_NAME="lims-$CLIENT_SLUG"
  export COMPOSE_FILE="$DEPLOY_ROOT/compose/docker-compose.yml"
  use_storage_defaults
  BACKUP_DIR="${LIMS_BACKUP_DIR:-$CLIENT_DIR/backups}"
  export BACKUP_DIR
  # Folders provisioned before the owner credentials moved to migrate.env: split them now, so
  # compose finds migrate.env and generated.env stops carrying the owner password.
  if [ -f "$CLIENT_DIR/secrets.env" ] && { [ ! -f "$CLIENT_DIR/migrate.env" ] || grep -q '^MIGRATION_DATABASE_URL=' "$CLIENT_DIR/generated.env" 2>/dev/null; }; then
    write_generated_env
  fi
}

# The store, when deployment.env names none. An install that names its own image keeps it, and its own command.
DEFAULT_S3_IMAGE="versity/versitygw:v1.11.0"
use_storage_defaults() {
  S3_IMAGE="${S3_IMAGE:-$DEFAULT_S3_IMAGE}"
  # --sidecar keeps each file's type and checksum in ordinary files. Without it they are filesystem attributes, which
  # the tar in backup.sh does not carry: a restored PDF would come back as plain text.
  case "$S3_IMAGE" in
    versity/versitygw:*) S3_COMMAND="${S3_COMMAND:---port :9000 posix --sidecar /data/meta /data/objects}" ;;
  esac
  export S3_IMAGE S3_COMMAND="${S3_COMMAND:-server /data}"
}

# The store expects its folders to exist.
prepare_storage() {
  case "$S3_IMAGE" in
    versity/versitygw:*) compose run --rm -T --no-deps --entrypoint sh minio -c 'mkdir -p /data/objects /data/meta' ;;
  esac
}

compose() { docker compose --env-file "$CLIENT_DIR/secrets.env" --env-file "$CLIENT_DIR/versions.env" --env-file "$CLIENT_DIR/deployment.env" "$@"; }

random_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

# One line of an env file that Compose reads back exactly, whatever the value holds. Its own escapes, not the shell's.
put() {
  local v="$2"
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"; v="${v//$'\n'/\\n}"
  printf '%s="%s"\n' "$1" "$v"
}

# Everything the app needs, derived from deployment.env and secrets.env. The lab's own details are not here:
# the administrator sets them in the app after the first sign-in.
# generated.env goes to the api and worker, so it carries only the lims_app role. The owner
# credentials go to migrate.env, which only the migrate service loads (see compose).
write_generated_env() {
  local out="$CLIENT_DIR/generated.env"
  umask 077
  # Only what deployment.env sets: an empty value would replace the app's own default.
  put_if_set() { local name; for name in "$@"; do [ -z "${!name:-}" ] || put "$name" "${!name}"; done; }
  {
    put BRAND_NAME "${BRAND_NAME:-LIMS}"
    put NODE_ENV "production"
    put PORT "3000"
    put TRUST_PROXY "true"
    put COOKIE_SECURE "true"
    put DATABASE_URL "postgresql://lims_app:${POSTGRES_APP_PASSWORD}@postgres:5432/lims"
    put DATABASE_READ_URL "${DATABASE_READ_URL:-}"
    put REDIS_URL "redis://:${REDIS_PASSWORD}@redis:6379/0"
    put SESSION_SECRET "${SESSION_SECRET}"
    put SETUP_TOKEN "${SETUP_TOKEN}"
    put FRONTEND_ORIGIN "https://${APP_DOMAIN}"
    put PUBLIC_API_URL "https://${API_DOMAIN}"
    put S3_ENDPOINT "http://lims-${CLIENT_SLUG}-storage:9000"
    put S3_PUBLIC_ENDPOINT "https://${FILES_DOMAIN}"
    put S3_BUCKET "lims"
    put S3_ACCESS_KEY "${S3_ACCESS_KEY}"
    put S3_SECRET_KEY "${S3_SECRET_KEY}"
    put SMTP_HOST "${SMTP_HOST}"
    put SMTP_PORT "${SMTP_PORT}"
    put SMTP_SECURE "${SMTP_SECURE}"
    put SMTP_USER "${SMTP_USER:-}"
    put SMTP_PASSWORD "${SMTP_PASSWORD:-}"
    put SMTP_FROM "${SMTP_FROM}"
    put SMTP_TRANSPORT "${SMTP_TRANSPORT:-smtp}"
    put ERROR_TRACKING_DSN "${ERROR_TRACKING_DSN:-}"
    put WHATSAPP_TOKEN "${WHATSAPP_TOKEN:-}"
    put WHATSAPP_PHONE_NUMBER_ID "${WHATSAPP_PHONE_NUMBER_ID:-}"
    put WHATSAPP_APP_SECRET "${WHATSAPP_APP_SECRET:-}"
    put WHATSAPP_VERIFY_TOKEN "${WHATSAPP_VERIFY_TOKEN:-}"
    put EINVOICE_PROVIDER "${EINVOICE_PROVIDER:-}"
    put EINVOICE_ENV "${EINVOICE_ENV:-}"
    put EINVOICE_BASE_URL "${EINVOICE_BASE_URL:-}"
    put EINVOICE_CLIENT_ID "${EINVOICE_CLIENT_ID:-}"
    put EINVOICE_CLIENT_SECRET "${EINVOICE_CLIENT_SECRET:-}"
    put EINVOICE_USERNAME "${EINVOICE_USERNAME:-}"
    put EINVOICE_PASSWORD "${EINVOICE_PASSWORD:-}"
    put EINVOICE_GSTIN "${EINVOICE_GSTIN:-}"
    put EINVOICE_PUBLIC_KEY "${EINVOICE_PUBLIC_KEY:-}"
    put ENABLE_AI_ASSISTANT "${ENABLE_AI_ASSISTANT:-}"
    put AI_PROVIDER "${AI_PROVIDER:-}"
    put AI_API_KEY "${AI_API_KEY:-}"
    put AI_MODEL "${AI_MODEL:-}"
    put AI_BASE_URL "${AI_BASE_URL:-}"
    put AI_PRICE_INPUT "${AI_PRICE_INPUT:-}"
    put AI_PRICE_OUTPUT "${AI_PRICE_OUTPUT:-}"
    put AI_FALLBACK_PROVIDER "${AI_FALLBACK_PROVIDER:-}"
    put AI_FALLBACK_MODEL "${AI_FALLBACK_MODEL:-}"
    put AI_FALLBACK_API_KEY "${AI_FALLBACK_API_KEY:-}"
    put AI_FALLBACK_BASE_URL "${AI_FALLBACK_BASE_URL:-}"
    put AI_FALLBACK_PRICE_INPUT "${AI_FALLBACK_PRICE_INPUT:-}"
    put AI_FALLBACK_PRICE_OUTPUT "${AI_FALLBACK_PRICE_OUTPUT:-}"
    put EMBEDDING_PROVIDER "${EMBEDDING_PROVIDER:-}"
    put EMBEDDING_API_KEY "${EMBEDDING_API_KEY:-}"
    put EMBEDDING_MODEL "${EMBEDDING_MODEL:-}"
    put HELP_INDEX_URL "${HELP_INDEX_URL:-}"
    put RATE_LIMIT_PER_MINUTE "${RATE_LIMIT_PER_MINUTE:-}"
    put RATE_LIMIT_PER_DAY "${RATE_LIMIT_PER_DAY:-}"
    put SIGNED_IN_RATE_LIMIT_PER_DAY "${SIGNED_IN_RATE_LIMIT_PER_DAY:-}"
    put DAILY_BUDGET_LIMIT "${DAILY_BUDGET_LIMIT:-}"
    put MONTHLY_BUDGET_LIMIT "${MONTHLY_BUDGET_LIMIT:-}"
    put MAX_QUESTION_LENGTH "${MAX_QUESTION_LENGTH:-}"
    put MAX_OUTPUT_TOKENS "${MAX_OUTPUT_TOKENS:-}"
    put TURNSTILE_SITE_KEY "${TURNSTILE_SITE_KEY:-}"
    put TURNSTILE_SECRET_KEY "${TURNSTILE_SECRET_KEY:-}"
    put AI_REQUIRE_LOGIN "${AI_REQUIRE_LOGIN:-}"
    put ALLOWED_ORIGINS "${ALLOWED_ORIGINS:-}"
    put HELP_SUPPORT_EMAIL "${HELP_SUPPORT_EMAIL:-}"
    put HELP_LOG_RETENTION_DAYS "${HELP_LOG_RETENTION_DAYS:-}"
    put SESSION_MAX_HOURS "${SESSION_MAX_HOURS:-12}"
    put PINCODE_LOOKUP_URL "${PINCODE_LOOKUP_URL-https://api.postalpincode.in/pincode/}"
    put_if_set LICENCE LOG_LEVEL SESSION_IDLE_MINUTES DATABASE_POOL_SIZE MAX_UPLOAD_BYTES
  } > "$out"
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
