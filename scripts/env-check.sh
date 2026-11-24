#!/usr/bin/env bash
# Proves that a value in deployment.env reaches the app unchanged, whatever characters it holds. Needs Docker.
. "$(dirname "$0")/lib/common.sh"
T="$(mktemp -d "${ENV_CHECK_DIR:-$DEPLOY_ROOT}/.env-check-XXXXXX")"
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2016 # these are the awkward values themselves
values=('p$w"d\x' '$HOME ${PATH} $$ `id` & | ; #x' "it's 'q' \\n end\\" $'line1\nline2' '  lead trail  ' '100%=a&b\c\\d' '')
names=()
for i in "${!values[@]}"; do
  put "V$i" "${values[$i]}"
  names+=("V$i")
done > "$T/out.env"
cat > "$T/compose.yml" <<'EOF'
services:
  show:
    image: alpine:3
    env_file: [out.env]
    command: ['sh', '-c', 'for n in $$NAMES; do eval "printf %s:%s\| $$n \"\$$$$n\""; done']
EOF
got="$(docker compose -p lims-env-check -f "$T/compose.yml" run --rm -e NAMES="${names[*]}" show 2>/dev/null)"
docker compose -p lims-env-check -f "$T/compose.yml" down >/dev/null 2>&1
want="$(for i in "${!values[@]}"; do printf '%s:%s|' "V$i" "${values[$i]}"; done)"
[ "$got" = "$want" ] || die "$(printf 'Values changed on the way.\nwant: %s\ngot:  %s' "$want" "$got")"
echo "ok: values reach the app unchanged"
