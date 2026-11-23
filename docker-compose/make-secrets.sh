#!/bin/sh
# Makes each secret once. An existing one is never replaced: that would lock the installation out of its own data.
set -eu
umask 022
cd /run/lims
make() {
  [ -s "$1" ] && return 0
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$2" > "$1.part"
  mv "$1.part" "$1"
}
make owner-password 40
make app-password 40
make redis-password 40
make s3-access-key 20
make s3-secret-key 40
make session-secret 64
make setup-token 32
