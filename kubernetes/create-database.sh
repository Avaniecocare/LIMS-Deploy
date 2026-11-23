#!/usr/bin/env bash
# Makes one company's database and its two roles on RDS, from inside the cluster (the database is private):
#   kubernetes/create-database.sh SLUG --master-secret ARN [--region ap-south-1]
# Needs aws (allowed to read the secrets) and kubectl (cluster administrator). Only verifiers of the two roles'
# passwords, and the master password, reach the cluster, in a secret that is removed at the end. Nothing is printed. Safe to run again: existing roles get
# the current passwords, and existing data is not touched.
set -euo pipefail
slug="${1:-}"; shift || true
master=""; region="ap-south-1"
while [ $# -gt 0 ]; do
  case "$1" in
    --master-secret) master="${2:-}"; shift 2 ;;
    --region) region="${2:-}"; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 64 ;;
  esac
done
[[ "$slug" =~ ^[a-z][a-z0-9-]{1,19}$ ]] && [ -n "$master" ] || { echo "Usage: create-database.sh SLUG --master-secret ARN [--region R]" >&2; exit 64; }
db="lims_${slug//-/_}"
ns=lims-database-setup
work="$(mktemp -d)"; chmod 700 "$work"
cleanup() { kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
secret() { aws secretsmanager get-secret-value --region "$region" --secret-id "$1" --query SecretString --output text; }
field() { python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]], end="")' "$1"; }
# postgresql://role:password@host:5432/db?...
# What PostgreSQL stores for a password (RFC 5803), so the password itself never enters the cluster or a log.
verifier() { python3 -I -c '
import base64, hashlib, hmac, os, sys
password, salt, rounds = sys.stdin.buffer.read(), os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", password, salt, rounds)
key = lambda name: hmac.new(salted, name, "sha256").digest()
b64 = lambda b: base64.b64encode(b).decode()
stored, server = hashlib.sha256(key(b"Client Key")).digest(), key(b"Server Key")
print("SCRAM-SHA-256$%d:%s$%s:%s" % (rounds, b64(salt), b64(stored), b64(server)), end="")'; }
part() { python3 -I -c 'import sys,urllib.parse as u; p=u.urlsplit(sys.stdin.read().strip()); print({"password":p.password,"host":p.hostname}[sys.argv[1]], end="")' "$1"; }

app_url="$(secret "lims/prod/$slug/app" | field DATABASE_URL)"
owner_url="$(secret "lims/prod/$slug/migrate" | field MIGRATION_DATABASE_URL)"
printf '%s' "$app_url" | part password | verifier > "$work/app"
printf '%s' "$owner_url" | part password | verifier > "$work/owner"
printf '%s' "$app_url" | part host > "$work/host"
secret "$master" | field password > "$work/master"
for f in app owner host master; do [ -s "$work/$f" ] || { echo "Could not read $f" >&2; exit 1; }; done

kubectl create namespace "$ns" >/dev/null
kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=restricted >/dev/null
kubectl -n "$ns" create secret generic db --from-file="$work" >/dev/null
kubectl -n "$ns" create configmap sql --from-file=setup.sql="$(dirname "$0")/create-database.sql" >/dev/null
kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: setup }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, fsGroup: 70, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: psql
          image: postgres:18-alpine
          command: [sh, -euc, 'export PGPASSWORD="\$(cat /s/master)"; psql "host=\$(cat /s/host) user=lims_master dbname=postgres sslmode=require" -X -q -v ON_ERROR_STOP=1 -v db=$db -v owner_verifier="\$(cat /s/owner)" -v app_verifier="\$(cat /s/app)" -f /q/setup.sql']
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources: { limits: { memory: 128Mi } }
          volumeMounts: [{ name: s, mountPath: /s, readOnly: true }, { name: q, mountPath: /q, readOnly: true }]
      volumes: [{ name: s, secret: { secretName: db, defaultMode: 0440 } }, { name: q, configMap: { name: sql } }]
YAML
if ! kubectl -n "$ns" wait --for=condition=Complete job/setup --timeout=240s >/dev/null 2>&1; then kubectl -n "$ns" logs job/setup --tail=20 >&2 || true; echo "The database was not set up" >&2; exit 1; fi
echo "Database $db is ready, with roles ${db}_owner and ${db}_app"
