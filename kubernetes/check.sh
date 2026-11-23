#!/usr/bin/env bash
# Runs the manifests on a throwaway single-node cluster (k3s in Docker) and checks them by use. Needs Docker, kubectl and
# two local images tagged k8s-test (and optionally k8s-test2 of the backend, to upgrade to). Removes everything.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
K3S_IMAGE="${K3S_IMAGE:?name a pinned rancher/k3s image}"
name=lims-k8s-check
work="$(mktemp -d)"
ns=lims-local
say() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then kubectl -n "$ns" get pods,jobs >&2 2>/dev/null || true; kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 >&2 || true; fi
  docker rm -fv "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

say "Cluster"
docker run -d --privileged --name "$name" -p 127.0.0.1:16443:6443 "$K3S_IMAGE" server --disable traefik --disable metrics-server --disable servicelb >/dev/null
export KUBECONFIG="$work/kubeconfig"
for _ in $(seq 1 60); do docker exec "$name" cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG" 2>/dev/null && [ -s "$KUBECONFIG" ] && break; sleep 2; done
sed -i.bak 's/:6443/:16443/' "$KUBECONFIG"
for _ in $(seq 1 60); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 2; done
kubectl get nodes | grep -q ' Ready' || fail "the cluster did not start"
for i in ghcr.io/avaniecocare/lims:k8s-test ghcr.io/avaniecocare/lims-ui:k8s-test postgres:18-alpine redis:8-alpine versity/versitygw:v1.11.0; do
  docker save "$i" | docker exec -i "$name" ctr -n k8s.io images import --all-platforms=false - >/dev/null || fail "could not load $i"
done
docker exec "$name" ctr -n k8s.io images tag ghcr.io/avaniecocare/lims:k8s-test ghcr.io/avaniecocare/lims:k8s-test2 >/dev/null
ok "started, images loaded"

say "Secrets and stand-ins for RDS and S3"
r() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40 || true; }
owner="$(r)"; app="$(r)"; redis="$(r)"; ak="$(r)"; sk="$(r)"; token="$(r)"
kubectl kustomize "$here/overlays/local" > "$work/all.yaml"
kubectl apply -f "$here/overlays/local/namespace.yaml" >/dev/null
kubectl -n "$ns" create secret generic lims-secrets --from-literal=DATABASE_URL="postgresql://lims_app:$app@postgres:5432/lims" --from-literal=REDIS_PASSWORD="$redis" --from-literal=REDIS_URL="redis://:$redis@redis:6379/0" --from-literal=SESSION_SECRET="$(r)$(r)" --from-literal=SETUP_TOKEN="$token" --from-literal=S3_ACCESS_KEY="$ak" --from-literal=S3_SECRET_KEY="$sk" >/dev/null
kubectl -n "$ns" create secret generic lims-migrate --from-literal=MIGRATION_DATABASE_URL="postgresql://lims_owner:$owner@postgres:5432/lims" >/dev/null
kubectl -n "$ns" create secret generic stand-in --from-literal=owner="$owner" --from-literal=app="$app" >/dev/null
kubectl -n "$ns" create configmap stand-in-init --from-file=10-app-role.sh="$here/../compose/db-init.sh" >/dev/null
kubectl apply -f "$work/all.yaml" -l '!app' >/dev/null
kubectl apply -f "$work/all.yaml" -l stand-in=true >/dev/null
for d in postgres storage; do kubectl -n "$ns" rollout status "deployment/$d" --timeout=180s >/dev/null || fail "$d did not start"; done
ok "running under the restricted pod security standard"

say "deploy.sh installs it"
"$here/deploy.sh" "$here/overlays/local"
kubectl -n "$ns" get pods --no-headers | grep -vE 'Running|Completed' && fail "a pod is not running"
ok "migrated, and api, worker, ui and redis are ready"

say "A person uses it, through the cluster's own network"
pod() { # namespace name app-label: a pod that waits
  kubectl -n "$1" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $2, labels: { app: $3 } }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: ghcr.io/avaniecocare/lims:k8s-test
      imagePullPolicy: Never
      command: [sleep, '3600']
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      resources: { requests: { memory: 16Mi }, limits: { memory: 192Mi } }
YAML
  kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout=120s >/dev/null
}
pod "$ns" customer customer
cat > "$work/use.js" <<'JS'
const P='K8s-Check-12!',H={'Content-Type':'application/json',Origin:'http://ui'},B='http://api/api/v1';
(async()=>{
 const page=await fetch('http://ui/');if(page.status!==200)throw new Error('ui '+page.status);
 if(!(await (await fetch('http://ui/config.js')).text()).includes('http://api'))throw new Error('config.js');
 if((await fetch('http://ui/help/')).status!==200)throw new Error('help');
 let r=await fetch(B+'/public/setup',{method:'POST',headers:H,body:JSON.stringify({setupToken:process.argv[2],adminEmail:'o@k.example',adminName:'Owner',adminPassword:P})});
 if(!r.ok&&r.status!==409)throw new Error('setup '+r.status+' '+await r.text());
 r=await fetch(B+'/auth/login',{method:'POST',headers:H,body:JSON.stringify({email:'o@k.example',password:P})});
 const j=await r.json();const A={...H,cookie:r.headers.getSetCookie()[0].split(';')[0],'X-CSRF-Token':j.user.csrfToken};
 r=await fetch(B+'/documents',{method:'POST',headers:A,body:JSON.stringify({kind:'mis:outstanding-ageing',params:{format:'pdf'}})});
 let d=await r.json();if(!r.ok)throw new Error(JSON.stringify(d));
 for(let i=0;i<120&&!['DONE','FAILED'].includes(d.status);i++){await new Promise(x=>setTimeout(x,1000));d=await (await fetch(B+'/documents/'+d.id,{headers:A})).json();}
 if(d.status!=='DONE')throw new Error('document '+JSON.stringify(d));
 const f=await fetch(d.url);const b=Buffer.from(await f.arrayBuffer());
 if(f.status!==200||b.subarray(0,5).toString()!=='%PDF-')throw new Error('file '+f.status);
 console.log('ok');
})().catch(e=>{console.error(e);process.exit(1)});
JS
inpod() { kubectl -n "$1" exec -i "$2" -- "${@:3}"; }
inpod "$ns" customer node - "$token" < "$work/use.js" | grep -q '^ok' || fail "use"
ok "screens, help, setup, sign-in, a PDF from Chromium on a read-only filesystem, and its signed link"

say "Who can reach what"
reach() { inpod "$1" "$2" node -e "const s=require('net').connect($4,'$3');s.setTimeout(4000,()=>process.exit(1));s.on('connect',()=>process.exit(0));s.on('error',()=>process.exit(1))" >/dev/null 2>&1; }
can() { reach "$@" || fail "$2 in $1 should reach $3:$4"; ok "$2 in $1 reaches $3:$4"; }
cannot() { if reach "$@"; then fail "$2 in $1 reached $3:$4"; fi; ok "$2 in $1 cannot reach $3:$4"; }
for n in lims-other monitoring; do kubectl create namespace "$n" >/dev/null; pod "$n" visitor visitor; done
can "$ns" customer api 80
cannot "$ns" customer redis 6379
cannot "$ns" customer api 9464
cannot lims-other visitor "api.$ns" 80
cannot lims-other visitor "redis.$ns" 6379
cannot lims-other visitor "postgres.$ns" 5432
api_ip="$(kubectl -n "$ns" get pod -l app=api -o jsonpath='{.items[0].status.podIP}')"
worker_ip="$(kubectl -n "$ns" get pod -l app=worker -o jsonpath='{.items[0].status.podIP}')"
cannot lims-other visitor "$api_ip" 9464
can monitoring visitor "$worker_ip" 9464
cannot monitoring visitor "$api_ip" 3000
inpod monitoring visitor node -e "fetch('http://$worker_ip:9464/metrics').then(r=>r.text()).then(t=>{if(!/lims_queue_jobs/.test(t)||!/lims_jobs_total\{queue=\"documents\",result=\"completed\"\} [1-9]/.test(t))throw new Error(t.slice(0,300));console.log('ok')})" | grep -q '^ok' || fail "metrics"
ok "monitoring reads the worker's metrics, the PDF counted"
inpod "$ns" deploy/api node -e "require('fs').writeFileSync('/app/x','x')" 2>/dev/null && fail "the app's files can be written"
ok "the app's files are read-only"
inpod "$ns" deploy/api sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token' || fail "a Kubernetes token is mounted"
inpod "$ns" deploy/api sh -c '! env | grep -q MIGRATION_DATABASE_URL' || fail "the app holds the owner's password"
ok "no Kubernetes token and no table-owner password in the app"

say "Upgrade, and an upgrade that does not work"
cp -R "$here" "$work/k"
sed -i.bak 's/newTag: k8s-test }/newTag: k8s-test2 }/' "$work/k/overlays/local/kustomization.yaml"
sed -i.bak 's#lims-ui, newTag: k8s-test2#lims-ui, newTag: k8s-test#' "$work/k/overlays/local/kustomization.yaml"
"$work/k/deploy.sh" "$work/k/overlays/local" > "$work/up.log" 2>&1 || { cat "$work/up.log" >&2; fail "upgrade"; }
image() { kubectl -n "$ns" get deployment api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
case "$(image)" in *:k8s-test2) ok "upgraded" ;; *) fail "image is $(image)" ;; esac
# A setting the app refuses to start with.
sed -i.bak 's/TRUST_PROXY=1/TRUST_PROXY=nonsense/' "$work/k/overlays/local/kustomization.yaml"
sed -i.bak 's/--timeout=300s/--timeout=60s/' "$work/k/deploy.sh"
if "$work/k/deploy.sh" "$work/k/overlays/local" > "$work/bad.log" 2>&1; then fail "a version that cannot start was accepted"; fi
grep -q 'Putting the previous version back' "$work/bad.log" || { cat "$work/bad.log" >&2; fail "it was not put back"; }
inpod "$ns" customer node - "$token" < "$work/use.js" | grep -q '^ok' || fail "not working after the failed upgrade"
ok "the failed upgrade was refused, the previous version put back, and work goes on"

say "Kubernetes check passed"
