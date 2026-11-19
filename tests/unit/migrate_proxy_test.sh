#!/usr/bin/env bash
# Golden-file tests for bin/app-migrate-proxy: the apps in tests/fixtures/migrate (production
# label shapes with neutral names and .test hosts) translate to their expected site.caddy and
# compose.server.yml, and anything unsupported is a TODO that writes nothing.
# Runs inside the test image (tests/docker): real `docker compose config` (no daemon needed) behind
# a stub `docker`. INSTALL_DIR is /opt/multi-deploy, the path two-hosts' absolute env_file names; the
# container is thrown away afterwards.
set -euo pipefail

SRC=${SRC:-/src}
# shellcheck source=tests/assert.sh
source "$SRC/tests/assert.sh"

export INSTALL_DIR=/opt/multi-deploy
FIXTURES="$SRC/tests/fixtures/migrate"
APPS="$INSTALL_DIR/apps"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK" "$INSTALL_DIR"' EXIT
rm -rf "$INSTALL_DIR"
mkdir -p "$WORK/bin" "$APPS"
cp -r "$SRC/bin" "$INSTALL_DIR/bin"

REAL_DOCKER=$(command -v docker)
cat > "$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  compose) exec "$REAL_DOCKER" "\$@" ;;
  inspect) echo true ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
unset MD_WEB_NETWORK

GOLDEN_APPS=(sse-healthcheck sse-app two-hosts www-apex plain-a plain-b auth-headers moved-host static-labels code-labels)

migrate() { rc=0; out=$("$INSTALL_DIR/bin/app-migrate-proxy" "$@" 2>&1) || rc=$?; }
tree_sum() { (cd "$1" && find . -type f -exec sha256sum {} + | sort); }
# install_fixture <fixture> [name]: copies a fixture app into apps/, renamed when name is given.
install_fixture() {
  local name=${2:-$1}
  rm -rf "${APPS:?}/$name"
  cp -r "$FIXTURES/$1" "$APPS/$name"
  rm -f "$APPS/$name"/expected.*
  sed -i "s/^NAME=.*/NAME=$name/" "$APPS/$name/app.env"
}

echo "# golden files"
for app in "${GOLDEN_APPS[@]}"; do
  install_fixture "$app"
  dir="$APPS/$app"
  before=$(tree_sum "$dir")
  # The file migrate-proxy edits: the app's own compose.yml for a static app, else compose.server.yml.
  edited=compose.server.yml
  [[ -f "$FIXTURES/$app/expected.compose.yml" ]] && edited=compose.yml

  migrate "$app"
  assert_eq "$app: the dry run succeeds" 0 "$rc"
  assert_contains "$app: the dry run prints the expected site.caddy" "$out" "$(cat "$FIXTURES/$app/expected.site.caddy")"
  assert_contains "$app: the dry run prints the $edited diff" "$out" "+++ $edited (migrated)"
  assert_eq "$app: the dry run writes nothing" "$before" "$(tree_sum "$dir")"
  assert_not_contains "$app: no env value of the merged config is printed" "$out" "must-not-leak"

  migrate "$app" --write
  assert_eq "$app: --write succeeds" 0 "$rc"
  assert_eq "$app: site.caddy is the golden file" "$(cat "$FIXTURES/$app/expected.site.caddy")" "$(cat "$dir/site.caddy" 2>/dev/null)"
  assert_eq "$app: $edited is the golden file" "$(cat "$FIXTURES/$app/expected.$edited")" "$(cat "$dir/$edited")"
  assert_cmd "$app: $edited.traefik.bak is the original" cmp -s "$FIXTURES/$app/$edited" "$dir/$edited.traefik.bak"
  if [[ -d "$FIXTURES/$app/code" ]]; then
    assert_eq "$app: code/ is not edited" "$(tree_sum "$FIXTURES/$app/code")" "$(tree_sum "$dir/code")"
  fi
  assert_not_contains "$app: no env value of the merged config is written" "$(cat "$dir/site.caddy" "$dir/$edited")" "must-not-leak"
  assert_cmd "$app: the migrated stack is a valid compose config" \
    docker compose --project-name "$app" -f "$dir/compose.yml" config --quiet

  migrate "$app" --write
  if [[ "$app" == code-labels ]]; then
    assert_eq "code-labels: labels stay in code/; a migrated app is reported as migrated" \
      "0 code-labels is migrated: site.caddy exists and app is aliased code-labels-app; its Traefik labels in code/ are inert." "$rc $(tail -n1 <<< "$out")"
  else
    assert_eq "$app: a migrated app has nothing left to migrate" "0 No Traefik labels in the compose config of $app; nothing to migrate." "$rc $out"
  fi
done

aliases=$(cd "$APPS/code-labels" && docker compose -p code-labels -f compose.yml config --format json | jq -c '.services.app.networks')
assert_eq "migrated code-labels: compose.server.yml aliases the service whose labels live in code/" '{"web":{"aliases":["code-labels-app"]}}' "$aliases"

aliases=$(cd "$APPS/two-hosts" && docker compose -p two-hosts -f compose.yml config --format json | jq -c '.services.api.networks')
assert_eq "migrated two-hosts: compose aliases api on the proxy network" '{"web":{"aliases":["two-hosts-api"]}}' "$aliases"
out=$("$INSTALL_DIR/bin/app-proxy" validate 2>&1) && rc=0 || rc=$?
assert_eq "the migrated sites pass app-proxy validate's cross-app checks" "0 Proxy config is valid." "$rc $out"

out=$("$INSTALL_DIR/bin/app" migrate-proxy 2>&1) && rc=0 || rc=$?
assert_eq "app migrate-proxy without a name prints its usage" "1" "$rc"
assert_contains "app usage lists migrate-proxy" "$("$INSTALL_DIR/bin/app" help)" "migrate-proxy <name> [--write]"
install_fixture plain-a via-app
out=$("$INSTALL_DIR/bin/app" migrate-proxy via-app 2>&1) && rc=0 || rc=$?
assert_eq "app migrate-proxy <name> runs the dry run" 0 "$rc"
assert_contains "app migrate-proxy <name> prints the site" "$out" "reverse_proxy via-app-nginx:8080"

echo "# unsupported labels are TODOs and nothing is written"
install_fixture plain-a todo-app
dir="$APPS/todo-app"
# Extra labels after the last label of nginx.
# shellcheck disable=SC2016 # literal $$ and backticks of the compose labels
extra=(
  'traefik.http.routers.plain-a.middlewares=extra-auth,extra-limit'
  'traefik.http.middlewares.extra-auth.basicauth.users=user:$$apr1$$hash'
  'traefik.http.middlewares.extra-limit.ratelimit.average=10'
  'traefik.http.routers.extra-api.rule=Host(`auth.example-d.test`) && PathPrefix(`/api`)'
  'traefik.http.routers.extra-api.priority=10'
  'traefik.tcp.routers.extra-tcp.rule=HostSNI(`*`)'
  'traefik.http.middlewares.extra-cors.headers.accessControlAllowOriginList=*'
  'traefik.http.middlewares.extra-sso.forwardauth.address=https://sso.example.test/check'
  'traefik.http.middlewares.extra-sso.forwardauth.tls.insecureSkipVerify=true'
)
printf '      - "%s"\n' "${extra[@]}" > "$WORK/extra"
awk -v extra="$WORK/extra" '{ print } /plain-a-https.redirectscheme.permanent=true/ { while ((getline l < extra) > 0) print l }' \
  "$dir/compose.server.yml" > "$WORK/x"
cat "$WORK/x" > "$dir/compose.server.yml"
before=$(tree_sum "$dir")
for mode in dry --write; do
  if [[ "$mode" == dry ]]; then migrate todo-app; else migrate todo-app --write; fi
  assert_eq "unsupported labels ($mode): exit 2" 2 "$rc"
  assert_eq "unsupported labels ($mode): nothing is written" "$before" "$(tree_sum "$dir")"
  assert_contains "unsupported labels ($mode): basicauth is a TODO" "$out" "TODO traefik.http.middlewares.extra-auth.basicauth.users: middleware type basicauth"
  assert_not_contains "unsupported labels ($mode): the basicauth value is not printed" "$out" 'apr1'
  assert_contains "unsupported labels ($mode): an unknown middleware is a TODO" "$out" "TODO traefik.http.middlewares.extra-limit.ratelimit.average: middleware type ratelimit"
  assert_contains "unsupported labels ($mode): a path rule is a TODO" "$out" "TODO traefik.http.routers.extra-api.rule=Host(\`auth.example-d.test\`) && PathPrefix(\`/api\`): only Host"
  assert_contains "unsupported labels ($mode): a priority is a TODO" "$out" "TODO traefik.http.routers.extra-api.priority: router setting priority"
  assert_contains "unsupported labels ($mode): a tcp router is a TODO" "$out" "TODO traefik.tcp.routers.extra-tcp.rule"
  assert_contains "unsupported labels ($mode): an unknown headers setting is a TODO" "$out" "TODO traefik.http.middlewares.extra-cors.headers.accessControlAllowOriginList: headers setting"
  assert_contains "unsupported labels ($mode): an unknown forwardauth setting is a TODO" "$out" "TODO traefik.http.middlewares.extra-sso.forwardauth.tls.insecureSkipVerify: forwardauth setting"
done

install_fixture plain-a two-svc
sed -i 's/^  mongo:$/  mongo:\n    labels:\n      - "traefik.enable=true"/' "$APPS/two-svc/compose.server.yml"
before=$(tree_sum "$APPS/two-svc")
migrate two-svc --write
assert_eq "two proxied services: exit 2" 2 "$rc"
assert_contains "two proxied services: a TODO" "$out" "TODO services mongo nginx all carry Traefik labels"
assert_eq "two proxied services: nothing is written" "$before" "$(tree_sum "$APPS/two-svc")"

echo "# compose.server.yml shapes the editor does not know are refused"
install_fixture plain-a map-nets
sed -i 's/^      - default$/      default: {}/; /^      - web$/d' "$APPS/map-nets/compose.server.yml"
sed -i 's/^      default: {}$/      default: {}\n      web: {}/' "$APPS/map-nets/compose.server.yml"
before=$(tree_sum "$APPS/map-nets")
migrate map-nets --write
assert_eq "networks in map form: exit 2" 2 "$rc"
assert_contains "networks in map form: the reason" "$out" "the networks of nginx are not a plain list"
assert_eq "networks in map form: nothing is written" "$before" "$(tree_sum "$APPS/map-nets")"

install_fixture two-hosts crlf
sed -i 's/$/\r/' "$APPS/crlf/compose.server.yml"
sed -i 's#apps/two-hosts/.env#apps/crlf/.env#' "$APPS/crlf/compose.server.yml"
before=$(tree_sum "$APPS/crlf")
migrate crlf --write
assert_eq "CRLF line endings: exit 2" 2 "$rc"
assert_contains "CRLF line endings: the reason" "$out" "CRLF line endings"
assert_eq "CRLF line endings: nothing is written" "$before" "$(tree_sum "$APPS/crlf")"

finish "unit migrate-proxy"
