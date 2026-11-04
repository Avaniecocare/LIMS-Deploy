#!/usr/bin/env bash
# Writes the company's reverse proxy site, and reloads the proxy if it is running:
#   scripts/proxy-sync.sh --client-dir /srv/lims-clients/acme
# Sites live in PROXY_SITES_DIR (default /srv/lims-proxy/sites), outside this repository.
. "$(dirname "$0")/lib/common.sh"
parse_client_dir "$@"
load_client
SITES="${PROXY_SITES_DIR:-/srv/lims-proxy/sites}"
mkdir -p "$SITES"
cat > "$SITES/$CLIENT_SLUG.site" <<EOF
$APP_DOMAIN {
	import security
	reverse_proxy lims-$CLIENT_SLUG-ui-1:8080
}

$API_DOMAIN {
	import security
	request_body {
		max_size 20MB
	}
	reverse_proxy lims-$CLIENT_SLUG-api-1:3000
}

$FILES_DOMAIN {
	import security
	reverse_proxy lims-$CLIENT_SLUG-minio-1:9000 {
		header_up Host {upstream_hostport}
	}
}
EOF
if docker ps --format '{{.Names}}' | grep -q '^lims-proxy-caddy-1$'; then
  docker exec lims-proxy-caddy-1 caddy reload --config /etc/caddy/Caddyfile >/dev/null && log "Proxy reloaded"
fi
