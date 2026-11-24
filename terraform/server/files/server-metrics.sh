#!/usr/bin/env bash
# Sends the server's own figures to CloudWatch. Run every five minutes by lims-metrics.timer.
# LIMS_DRY_RUN=1 prints them instead.
set -euo pipefail
REGION="${LIMS_REGION:?}"
CLIENTS="${LIMS_CLIENTS_DIR:-/srv/lims-clients}"
DATA="${LIMS_DATA_DIR:-/srv}"

used() { df --output=pcent "$1" | tail -1 | tr -dc '0-9'; }
disk="$(used "$DATA")"
root="$(used /)"
memory="$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo)"

# Docker being down counts as trouble, not as "no unhealthy containers".
if list="$(docker ps --all --format '{{.State}} {{.Status}}' 2>/dev/null)"; then
  unhealthy="$(grep -cE '^restarting|\(unhealthy\)' <<<"$list" || true)"
else
  unhealthy=1
fi

# The company whose newest backup is oldest. A finished backup is a folder with a manifest, or an encrypted archive.
now="$(date +%s)"
age=0
for dir in "$CLIENTS"/*/; do
  [ -f "$dir/secrets.env" ] || continue # not provisioned yet
  newest="$(find "$dir/backups" -maxdepth 2 \( -name manifest.txt -o -name '*.tar.age' -o -name '*.tar.gpg' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1 || true)"
  if [ -n "$newest" ]; then
    hours=$(( (now - ${newest%.*}) / 3600 ))
  else
    hours=$(( (now - $(stat -c %Y "$dir/secrets.env")) / 3600 )) # none yet: since it was provisioned
  fi
  [ "$hours" -le "$age" ] || age="$hours"
done

figures="[{\"MetricName\":\"DiskUsedPercent\",\"Unit\":\"Percent\",\"Value\":$disk},{\"MetricName\":\"RootDiskUsedPercent\",\"Unit\":\"Percent\",\"Value\":$root},{\"MetricName\":\"MemoryUsedPercent\",\"Unit\":\"Percent\",\"Value\":$memory},{\"MetricName\":\"UnhealthyContainers\",\"Unit\":\"Count\",\"Value\":$unhealthy},{\"MetricName\":\"BackupAgeHours\",\"Value\":$age}]"
if [ -n "${LIMS_DRY_RUN:-}" ]; then
  echo "$figures"
else
  aws cloudwatch put-metric-data --region "$REGION" --namespace LIMS/Server --metric-data "$figures"
fi
