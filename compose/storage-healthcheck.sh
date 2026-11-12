#!/bin/sh
# Healthcheck for the S3-compatible store, mounted into whatever S3_IMAGE is. The image is chosen
# per deployment, so this uses whichever probe the image has. Any HTTP answer on port 9000 (even
# 403, since requests here are unsigned) means the server is up; a refused connection means not.
set -u
url="http://127.0.0.1:9000/"

if command -v curl >/dev/null 2>&1; then
  # curl exits 0 on any HTTP response without -f; 7 = refused, 28 = timeout.
  exec curl -s -o /dev/null -m 4 "$url"
fi

if command -v wget >/dev/null 2>&1; then
  out="$(wget -q -T 4 -O /dev/null "$url" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && exit 0
  [ "$rc" -eq 8 ] && exit 0 # GNU wget: the server answered with an HTTP error
  case "$out" in *"HTTP/"*|*"server returned error"*) exit 0 ;; esac # BusyBox wget
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  exec node -e "const s=require('net').connect(9000,'127.0.0.1');s.setTimeout(4000,()=>process.exit(1));s.on('connect',()=>process.exit(0));s.on('error',()=>process.exit(1))"
fi

if command -v nc >/dev/null 2>&1; then
  exec nc -z -w 4 127.0.0.1 9000
fi

echo "storage-healthcheck: no curl, wget, node or nc in this image; set S3_HEALTHCHECK_CMD in deployment.env" >&2
exit 1
