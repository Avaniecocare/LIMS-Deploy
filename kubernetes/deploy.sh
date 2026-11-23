#!/usr/bin/env bash
# Installs or upgrades one company:
#   kubernetes/deploy.sh OVERLAY_FOLDER [--context NAME]
# Migrations run first, as the table owner. If they fail, nothing running is touched. If the new version does not become
# ready, the previous one is put back. Migrations only go forward: the versions before and after must both work with the
# new tables, and going further back means restoring a database snapshot.
set -euo pipefail
overlay="${1:-}"; shift || true
[ -f "$overlay/kustomization.yaml" ] || { echo "Usage: deploy.sh OVERLAY_FOLDER [--context NAME]" >&2; exit 64; }
k=(kubectl "$@")
rendered="$(mktemp)"; trap 'rm -f "$rendered"' EXIT
kubectl kustomize "$overlay" > "$rendered"
ns="$(awk '/^kind: Namespace$/{f=1} f&&/^  name:/{print $2; exit}' "$rendered")"
[ -n "$ns" ] || { echo "The overlay has no Namespace" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

log "Namespace, settings and secrets"
"${k[@]}" apply -f "$rendered" -l '!app'
for s in lims-secrets lims-migrate; do
  for _ in $(seq 1 30); do "${k[@]}" -n "$ns" get secret "$s" >/dev/null 2>&1 && break; sleep 2; done
  "${k[@]}" -n "$ns" get secret "$s" >/dev/null || { echo "Secret $s did not appear in $ns" >&2; exit 1; }
done
"${k[@]}" apply -f "$rendered" -l app=redis

log "Migrations"
"${k[@]}" -n "$ns" delete job migrate --ignore-not-found --wait
"${k[@]}" apply -f "$rendered" -l app=migrate
done_=""
for _ in $(seq 1 180); do
  done_="$("${k[@]}" -n "$ns" get job migrate -o jsonpath='{.status.conditions[?(@.status=="True")].type}')"
  case "$done_" in *Complete*) break ;; *Failed*) break ;; esac
  sleep 5
done
"${k[@]}" -n "$ns" logs job/migrate --tail=20 || true
case "$done_" in *Complete*) ;; *) echo "Migrations did not finish. The running version was not touched." >&2; exit 1 ;; esac

log "New version"
first=false; "${k[@]}" -n "$ns" get deployment api >/dev/null 2>&1 || first=true
for d in api worker ui; do "${k[@]}" apply -f "$rendered" -l "app=$d"; done
for d in api worker ui; do
  if ! "${k[@]}" -n "$ns" rollout status "deployment/$d" --timeout=300s; then
    "${k[@]}" -n "$ns" get pods -o wide >&2 || true
    "${k[@]}" -n "$ns" logs "deployment/$d" --tail=30 >&2 || true
    if [ "$first" = false ]; then
      log "$d did not become ready. Putting the previous version back." >&2
      for u in api worker ui; do "${k[@]}" -n "$ns" rollout undo "deployment/$u" || true; done
      for u in api worker ui; do "${k[@]}" -n "$ns" rollout status "deployment/$u" --timeout=300s || true; done
    fi
    exit 1
  fi
done
log "Ready"
