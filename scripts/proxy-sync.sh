#!/usr/bin/env bash
# Writes the company's reverse proxy site, and reloads the proxy if it is running:
#   scripts/proxy-sync.sh --client-dir /srv/lims-clients/acme
# Sites live in PROXY_SITES_DIR (default /srv/lims-proxy/sites), outside this repository.
# Upstreams are the company's unique container names (lims-<slug>-<service>-1), never the generic
# service names, which every company shares on the lims-proxy network.
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
	# Browsers only ever fetch short-lived signed links (GET/HEAD with a SigV4 query signature).
	# Everything else on the S3 API, admin endpoints included, stays off the internet.
	@signed {
		method GET HEAD
		query X-Amz-Signature=*
	}
	handle @signed {
		reverse_proxy lims-$CLIENT_SLUG-minio-1:9000 {
			header_up Host {upstream_hostport}
		}
	}
	handle {
		respond 403
	}
}
EOF
if docker ps --format '{{.Names}}' | grep -q '^lims-proxy-caddy-1$'; then
  docker exec lims-proxy-caddy-1 caddy reload --config /etc/caddy/Caddyfile >/dev/null && log "Proxy reloaded"
fi
