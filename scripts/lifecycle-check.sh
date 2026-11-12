#!/usr/bin/env bash
# Exercises the whole operational lifecycle on two fictional companies, on a machine with Docker:
#   LIMS_VERSION=x LIMS_UI_VERSION=y NEXT_LIMS_VERSION=z scripts/lifecycle-check.sh [--keep]
# Provision, prove isolation, back up, restore, upgrade, roll back. Uses a throwaway work folder.
# Set LIFECYCLE_WORK_DIR if Docker can't bind-mount from the default temp location.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${LIFECYCLE_WORK_DIR:-$(mktemp -d)}"
mkdir -p "$WORK"
KEEP=false; [ "${1:-}" = "--keep" ] && KEEP=true
export PROXY_SITES_DIR="$WORK/sites"
export LIMS_SKIP_BACKUP_CRON=true # throwaway companies: no crontab entries
NEXT="${NEXT_LIMS_VERSION:-$LIMS_VERSION}"
say() { printf '\n=== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  [ "$KEEP" = true ] && { echo "Kept $WORK"; return; }
  for c in bluepeak greenfield; do
    if [ -f "$WORK/$c/secrets.env" ]; then
      COMPOSE_PROJECT_NAME="lims-$c" DEPLOY_ROOT="$ROOT" CLIENT_DIR="$WORK/$c" docker compose -f "$ROOT/compose/docker-compose.yml" --env-file "$WORK/$c/secrets.env" --env-file "$WORK/$c/versions.env" --env-file "$WORK/$c/deployment.env" down -v >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

setup() {
  local c="$1" dir="$WORK/$1"
  mkdir -p "$dir"
  cp -R "$ROOT/clients/example-$c/branding" "$dir/branding"
  cp "$ROOT/clients/example-$c/company.env.example" "$dir/company.env"
  cp "$ROOT/clients/example-$c/deployment.env.example" "$dir/deployment.env"
  printf 'LIMS_VERSION="%s"\nLIMS_UI_VERSION="%s"\n' "$LIMS_VERSION" "$LIMS_UI_VERSION" > "$dir/versions.env"
  # Script checks use a small local S3 server unless told otherwise.
  sed -i.bak "s#^S3_IMAGE=.*#S3_IMAGE=\"${S3_IMAGE:-lims-test-s3:local}\"#" "$dir/deployment.env" && rm -f "$dir/deployment.env.bak"
  "$ROOT/scripts/provision.sh" --client-dir "$dir"
}

api() { docker exec "lims-$1-api-1" node -e "$2"; }
branding() { api "$1" "fetch('http://localhost:3000/api/v1/public/branding').then(r=>r.json()).then(j=>console.log(j.companyName))"; }
psql_in() { local c="$1"; shift; docker exec "lims-$c-postgres-1" psql -U lims_owner -d lims -Atc "$*"; }
customers() { psql_in "$1" 'SELECT count(*) FROM "Customer"'; }
add_customer() { psql_in "$1" "INSERT INTO \"Customer\"(id,crn,name,\"stateName\",\"stateCode\",\"updatedAt\") VALUES (gen_random_uuid()::text,'$2','$2','X','27',now())" >/dev/null; }
run_image() { docker inspect --format '{{.Config.Image}}' "lims-$1-api-1"; }

if [ -z "${S3_IMAGE:-}" ]; then
  docker build -q -t lims-test-s3:local "$ROOT/compose/test-s3" >/dev/null
  export LIMS_S3_ACCESS_KEY=S3RVER LIMS_S3_SECRET_KEY=S3RVER # the local server accepts only its own key
fi
docker network inspect lims-proxy >/dev/null 2>&1 || docker network create lims-proxy >/dev/null

say "Provision two companies"
setup bluepeak
setup greenfield
[ "$(branding bluepeak)" = "BluePeak Testing Labs" ] || fail "bluepeak branding"
[ "$(branding greenfield)" = "Greenfield Analytical" ] || fail "greenfield branding"
echo "ok: each company answers with its own branding"

say "Real work through the images: first-run setup, sign-in, worker, storage, Chromium"
token="$(grep '^SETUP_TOKEN=' "$WORK/bluepeak/secrets.env" | cut -d= -f2 | tr -d '"')"
docker exec -e TOKEN="$token" lims-bluepeak-api-1 node -e "
const B='http://localhost:3000/api/v1',H={'Content-Type':'application/json'};
(async()=>{
 const P='Lifecycle-Check-1!';
 let r=await fetch(B+'/public/setup',{method:'POST',headers:H,body:JSON.stringify({setupToken:process.env.TOKEN,adminEmail:'owner@bluepeak.example',adminName:'Owner',adminPassword:P})});
 if(!r.ok)throw new Error('setup '+r.status+' '+await r.text());
 r=await fetch(B+'/auth/login',{method:'POST',headers:H,body:JSON.stringify({email:'owner@bluepeak.example',password:P})});
 const j=await r.json();const c=r.headers.getSetCookie()[0].split(';')[0];const A={...H,cookie:c,'X-CSRF-Token':j.user.csrfToken};
 r=await fetch(B+'/documents',{method:'POST',headers:A,body:JSON.stringify({kind:'mis:outstanding-ageing',params:{format:'pdf'}})});
 let d=await r.json();if(!r.ok)throw new Error(JSON.stringify(d));
 for(let i=0;i<60&&!['DONE','FAILED'].includes(d.status);i++){await new Promise(x=>setTimeout(x,1000));d=await (await fetch(B+'/documents/'+d.id,{headers:A})).json();}
 if(d.status!=='DONE')throw new Error('document '+JSON.stringify(d));
 console.log('ok: worker rendered a PDF with Chromium and stored it');
})().catch(e=>{console.error(e);process.exit(1)})" || fail "real work failed"

say "Separate data stores"
add_customer bluepeak BP-ONLY
[ "$(customers bluepeak)" = "1" ] || fail "bluepeak should have one customer"
[ "$(customers greenfield)" = "0" ] || fail "greenfield can see bluepeak data"
for s in postgres redis minio; do
  a="$(docker inspect --format '{{range .Mounts}}{{.Name}}{{end}}' "lims-bluepeak-$s-1")"
  b="$(docker inspect --format '{{range .Mounts}}{{.Name}}{{end}}' "lims-greenfield-$s-1")"
  [ "$a" != "$b" ] || fail "$s volume is shared"
done
[ "$(docker inspect --format '{{.Config.Image}}' lims-bluepeak-api-1)" = "$(docker inspect --format '{{.Config.Image}}' lims-greenfield-api-1)" ] || fail "different images"
echo "ok: separate databases, caches and storage; one image"

say "Only the migrate service holds the owner credentials"
for svc in api worker; do
  if docker exec "lims-bluepeak-$svc-1" printenv MIGRATION_DATABASE_URL >/dev/null 2>&1; then fail "$svc holds the owner credentials"; fi
done
grep -q '^MIGRATION_DATABASE_URL=' "$WORK/bluepeak/generated.env" && fail "generated.env carries the owner credentials"
echo "ok"

say "Storage is addressed by a per-company name"
grep -q '^S3_ENDPOINT="http://lims-bluepeak-storage:9000"' "$WORK/bluepeak/generated.env" || fail "S3_ENDPOINT is not per-company"
ips_a="$(api bluepeak "require('dns').promises.lookup('lims-bluepeak-storage',{all:true}).then(a=>console.log(a.length))")"
[ "$ips_a" = "1" ] || fail "lims-bluepeak-storage resolves to $ips_a addresses"
if api greenfield "require('dns').promises.lookup('lims-bluepeak-storage').then(()=>process.exit(0),()=>process.exit(1))" 2>/dev/null; then fail "greenfield can resolve bluepeak's storage"; fi
echo "ok"

say "App role cannot touch the audit log's protection"
owner="$(grep POSTGRES_APP_PASSWORD "$WORK/bluepeak/secrets.env" | cut -d= -f2 | tr -d '"')"
if docker exec -e PGPASSWORD="$owner" lims-bluepeak-postgres-1 psql -h localhost -U lims_app -d lims -c 'ALTER TABLE "AuditLog" DISABLE TRIGGER USER' 2>/dev/null; then fail "app role altered the audit log"; fi
echo "ok"

say "Back up and restore"
"$ROOT/scripts/backup.sh" --client-dir "$WORK/bluepeak" | tail -1 > "$WORK/last-backup"
backup="$(cat "$WORK/last-backup")"
add_customer bluepeak AFTER-BACKUP
[ "$(customers bluepeak)" = "2" ] || fail "second customer"
if "$ROOT/scripts/restore.sh" --client-dir "$WORK/greenfield" --from "$backup" --yes 2>/dev/null; then fail "restored another company's backup"; fi
"$ROOT/scripts/restore.sh" --client-dir "$WORK/bluepeak" --from "$backup" --yes
[ "$(customers bluepeak)" = "1" ] || fail "restore did not return to the backup"
[ "$(customers greenfield)" = "0" ] || fail "restore touched the other company"
[ "$(branding bluepeak)" = "BluePeak Testing Labs" ] || fail "app down after restore"
[ "$(psql_in bluepeak "SELECT count(*) FROM \"FileObject\"")" -ge 1 ] || fail "file record missing after restore"
echo "ok: restored; other company untouched; wrong-company backup refused"

say "Upgrade one company"
"$ROOT/scripts/upgrade.sh" --client-dir "$WORK/bluepeak" --lims "$NEXT"
case "$(run_image bluepeak)" in *":$NEXT") ;; *) fail "bluepeak did not move to $NEXT" ;; esac
case "$(run_image greenfield)" in *":$LIMS_VERSION") ;; *) fail "upgrade touched greenfield" ;; esac
echo "ok: bluepeak on $NEXT, greenfield still on $LIMS_VERSION"

say "Roll back"
add_customer bluepeak AFTER-UPGRADE
"$ROOT/scripts/rollback.sh" --client-dir "$WORK/bluepeak" --yes
"$ROOT/scripts/deploy.sh" --client-dir "$WORK/bluepeak"
case "$(run_image bluepeak)" in *":$LIMS_VERSION") ;; *) fail "rollback did not change the image" ;; esac
[ "$(customers bluepeak)" = "1" ] || fail "rollback did not restore data"
[ "$(branding bluepeak)" = "BluePeak Testing Labs" ] || fail "app down after rollback"
echo "ok: back on $LIMS_VERSION with the pre-upgrade data"

say "Lifecycle check passed"
