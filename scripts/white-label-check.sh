#!/usr/bin/env bash
# CI check: the SAME images run as two fictional companies; each must show only its own details.
#   LIMS_VERSION=x LIMS_UI_VERSION=y scripts/white-label-check.sh
# Uses throwaway folders outside the repo and removes everything when done.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export PROXY_SITES_DIR="$WORK/sites"
cleanup() {
  for c in bluepeak greenfield; do
    [ -f "$WORK/$c/secrets.env" ] && (cd "$WORK/$c" && COMPOSE_PROJECT_NAME="lims-$c" docker compose -f "$ROOT/compose/docker-compose.yml" --env-file secrets.env --env-file versions.env --env-file deployment.env down -v >/dev/null 2>&1 || true)
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

setup() {
  local c="$1"; local dir="$WORK/$c"
  mkdir -p "$dir"
  cp -R "$ROOT/clients/example-$c/branding" "$dir/branding"
  cp "$ROOT/clients/example-$c/company.env.example" "$dir/company.env"
  cp "$ROOT/clients/example-$c/deployment.env.example" "$dir/deployment.env"
  printf 'LIMS_VERSION="%s"\nLIMS_UI_VERSION="%s"\n' "$LIMS_VERSION" "$LIMS_UI_VERSION" > "$dir/versions.env"
  "$ROOT/scripts/provision.sh" --client-dir "$dir"
}

in_api() { docker exec "lims-$1-api-1" node -e "$2"; }

check() {
  local c="$1" own="$2" other="$3"
  branding="$(in_api "$c" "fetch('http://localhost:3000/api/v1/public/branding').then(r=>r.text()).then(console.log)")"
  echo "$branding" | grep -q "$own" || { echo "FAIL: $c branding lacks $own"; exit 1; }
  if echo "$branding" | grep -q "$other"; then echo "FAIL: $c branding shows $other"; exit 1; fi
  echo "$branding" | grep -qE 'bank|gstin|pan|account' && { echo "FAIL: $c public branding carries private fields"; exit 1; }
  echo "ok: $c"
}

setup bluepeak
setup greenfield
check bluepeak "BluePeak" "Greenfield"
check greenfield "Greenfield" "BluePeak"

img_a="$(docker inspect --format '{{.Image}}' lims-bluepeak-api-1)"
img_b="$(docker inspect --format '{{.Image}}' lims-greenfield-api-1)"
[ "$img_a" = "$img_b" ] || { echo "FAIL: companies are not running the same image"; exit 1; }
echo "White-label check passed: one image, two companies."
