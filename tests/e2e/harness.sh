#!/usr/bin/env bash
# Runs inside the e2e harness container (see tests/e2e/run.sh), with the host Docker socket,
# this checkout at /src (read-only) and the install volume at $MD_TEST_MOUNT.
set -euo pipefail

# shellcheck source=tests/assert.sh
source /src/tests/assert.sh

: "${MD_TEST_RUN:?}" "${MD_TEST_LABEL:?}" "${MD_TEST_VOLUME:?}" "${MD_TEST_MOUNT:?}"
: "${MD_TEST_NETWORK:?}" "${MD_TEST_SUBNET:?}" "${MD_TEST_ALT_SUBNET:?}"
: "${CADDY_IMAGE:?}" "${NGINX_IMAGE:?}" "${CURL_IMAGE:?}"

export INSTALL_DIR="$MD_TEST_MOUNT/opt/multi-deploy"
export MD_WEB_NETWORK="$MD_TEST_NETWORK" MD_WEB_SUBNET="$MD_TEST_SUBNET"
export MD_RESOURCE_LABEL="$MD_TEST_LABEL" MD_ACME_EMAIL=e2e@example.test
export MD_CADDY_IMAGE="$CADDY_IMAGE" MD_TEST_RUN
export REPO_URL=file:///tmp/src REPO_REF=md-test
CADDY=multi-deploy-caddy
ROOT_CA="$INSTALL_DIR/caddy/data/caddy-data/caddy/pki/authorities/local/root.crt"

# setup.sh installs from a git snapshot of the checkout, on a branch, to exercise REPO_REF.
rsync -a --exclude .git --exclude .claude --exclude brief-u2.md --exclude brief-u3.md --exclude .commitmsg /src/ /tmp/src/
git -C /tmp/src init -q -b md-test
git -C /tmp/src add -A
git -C /tmp/src -c user.name=e2e -c user.email=e2e@example.test commit -q -m snapshot

# Test-only additions next to the installed caddy/compose.yml: no host ports, the run label,
# and local_certs through the Caddyfile's test hook. setup.sh's rsync leaves them in place.
mkdir -p "$INSTALL_DIR/caddy"
cat > "$INSTALL_DIR/caddy/compose.override.yml" <<EOF
services:
  caddy:
    ports: !reset []
    labels:
      multi-deploy.test: "$MD_TEST_RUN"
    volumes:
      - ./test.caddy:/etc/caddy/test.caddy:ro
EOF
printf 'local_certs\nskip_install_trust\n' > "$INSTALL_DIR/caddy/test.caddy"

run_setup() { bash /tmp/src/setup.sh </dev/null 2>&1; }
caddy_state() { local s; s=$(docker inspect -f '{{.State.Running}}' "$CADDY" 2>/dev/null) || s=absent; echo "$s"; }
subnet_of() { local s; s=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$1" 2>/dev/null) || s=absent; echo "$s"; }
curl_run() {
  docker run --rm --label "$MD_TEST_LABEL" --network "$MD_WEB_NETWORK" --user 0 \
    -v "$MD_TEST_VOLUME:$MD_TEST_MOUNT:ro" "$CURL_IMAGE" -sS --max-time 10 "$@"
}

if [[ -n "$(docker ps -q --filter label=com.docker.compose.project=traefik)" ]]; then
  not_ok "a Traefik compose project runs on this Docker host; the fresh-install scenario cannot run"
  finish "e2e"; exit 1
fi

echo "# setup.sh on a host where Traefik runs"
docker run -d --name "md-test-traefik-$MD_TEST_RUN" --label "$MD_TEST_LABEL" \
  --label com.docker.compose.project=traefik "$NGINX_IMAGE" >/dev/null
out=$(run_setup) && rc=0 || rc=$?
assert_eq "setup.sh succeeds" 0 "$rc"
assert_contains "setup.sh points to the migration guide" "$out" "Caddy was NOT started"
assert_eq "Caddy is not started while Traefik runs" absent "$(caddy_state)"
assert_eq "the web network is not created while Traefik runs" absent "$(subnet_of "$MD_WEB_NETWORK")"
assert_cmd "files are installed" test -f "$INSTALL_DIR/caddy/Caddyfile"
docker rm -f "md-test-traefik-$MD_TEST_RUN" >/dev/null

echo "# fresh install"
out=$(run_setup) && rc=0 || rc=$?
assert_eq "setup.sh succeeds" 0 "$rc"
assert_contains "setup.sh creates the missing network" "$out" "Created network $MD_WEB_NETWORK (subnet: $MD_TEST_SUBNET)."
assert_eq "network has the configured subnet" "$MD_TEST_SUBNET" "$(subnet_of "$MD_WEB_NETWORK")"
assert_eq "Caddy runs with zero apps (app imports match nothing)" true "$(caddy_state)"
mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}' "$CADDY")
assert_not_contains "Caddy has no Docker socket" "$mounts" "docker.sock"
assert_contains "Caddy reads the apps directory" "$mounts" "$INSTALL_DIR/apps->/etc/caddy/apps"
assert_eq "Caddy publishes no host ports in the harness" "" "$(docker port "$CADDY")"
assert_cmd "REPO_REF branch was installed" test -f "$INSTALL_DIR/tests/e2e/harness.sh"
assert_contains "setup.sh skips systemd where it is absent" "$out" "systemd not found"

echo "# two apps"
cp -r /src/tests/fixtures/apps/app-one /src/tests/fixtures/apps/app-two "$INSTALL_DIR/apps/"
for app in app-one app-two; do
  assert_cmd "$app starts through bin/app-compose" "$INSTALL_DIR/bin/app-compose" "$app" up -d --quiet-pull
done
out=$("$INSTALL_DIR/bin/app" proxy reload 2>&1) && rc=0 || rc=$?
assert_eq "app proxy reload succeeds with both apps" 0 "$rc"
assert_contains "app global.caddy is applied" "$(docker exec "$CADDY" wget -qO- http://127.0.0.1:2019/config/)" '"endpoint":"http://app-one-web/ask"'

ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$MD_WEB_NETWORK\").IPAddress}}" "$CADDY")
for app in app-one app-two; do
  host="$app.test"
  body=""
  for _ in $(seq 1 30); do
    body=$(curl_run --cacert "$ROOT_CA" --resolve "$host:443:$ip" "https://$host/" 2>/dev/null) && break
    sleep 1
  done
  assert_eq "$host serves over TLS with Caddy's local CA" "$app" "$body"
  assert_eq "$host redirects http to https" "308 https://$host/" \
    "$(curl_run -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "$host:80:$ip" "http://$host/")"
done
headers=$(curl_run -o /dev/null -D - --cacert "$ROOT_CA" --resolve "app-one.test:443:$ip" https://app-one.test/)
assert_contains "security-headers snippet is applied" "${headers,,}" "strict-transport-security: max-age=31536000; includesubdomains; preload"
assert_contains "access log goes to stdout" "$(docker logs "$CADDY" 2>/dev/null | grep '"http.log.access' || true)" '"host":"app-two.test"'

echo "# reload with a broken app config"
mkdir -p "$INSTALL_DIR/apps/app-broken"
printf 'broken.test {\n\tnot_a_directive\n}\n' > "$INSTALL_DIR/apps/app-broken/site.caddy"
docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "reload refuses the broken config" 1 "$rc"
assert_eq "the running config keeps serving" app-one \
  "$(curl_run --cacert "$ROOT_CA" --resolve "app-one.test:443:$ip" https://app-one.test/)"
rm -rf "$INSTALL_DIR/apps/app-broken"

echo "# setup.sh again (update)"
out=$(MD_WEB_SUBNET="$MD_TEST_ALT_SUBNET" run_setup) && rc=0 || rc=$?
assert_eq "setup.sh succeeds" 0 "$rc"
assert_contains "existing network is kept and its subnet printed" "$out" "Network $MD_WEB_NETWORK exists, keeping it (subnet: $MD_TEST_SUBNET)."
assert_eq "network subnet is unchanged" "$MD_TEST_SUBNET" "$(subnet_of "$MD_WEB_NETWORK")"
assert_eq "Caddy still runs" true "$(caddy_state)"
assert_eq "app-two still serves" app-two \
  "$(curl_run --cacert "$ROOT_CA" --resolve "app-two.test:443:$ip" https://app-two.test/)"

echo "# app create, deploy and delete through the proxy"
# docker-prune.sh (run after every deploy) prunes the whole Docker host; the harness swaps in a no-op.
printf '#!/bin/sh\necho "docker-prune.sh skipped in the e2e harness"\n' > "$INSTALL_DIR/bin/docker-prune.sh"
mkdir -p /tmp/app-three-repo
cat > /tmp/app-three-repo/compose.yml <<EOF
services:
  web:
    image: $NGINX_IMAGE
    command: ["/bin/sh", "-c", "echo app-three > /usr/share/nginx/html/index.html && exec nginx -g 'daemon off;'"]
    labels:
      multi-deploy.test: "$MD_TEST_RUN"

networks:
  default:
    labels:
      multi-deploy.test: "$MD_TEST_RUN"
EOF
git -C /tmp/app-three-repo init -q -b main
git -C /tmp/app-three-repo add -A
git -C /tmp/app-three-repo -c user.name=e2e -c user.email=e2e@example.test commit -q -m app-three

app() { "$INSTALL_DIR/bin/app" "$@"; }
started_at() { docker inspect -f '{{.State.StartedAt}}' "$CADDY"; }
caddy_started=$(started_at)
serves() {
  local host="$1" body=""
  for _ in $(seq 1 30); do
    body=$(curl_run --cacert "$ROOT_CA" --resolve "$host:443:$ip" "https://$host/" 2>/dev/null) && break
    sleep 1
  done
  echo "$body"
}
ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$MD_WEB_NETWORK\").IPAddress}}" "$CADDY")

out=$(APP_CREATE_BRANCH=main APP_CREATE_SERVICE=web APP_CREATE_HOST=app-three.test APP_CREATE_PORT=80 \
  APP_CREATE_SSE=y APP_CREATE_HEADERS=y app create app-three file:///tmp/app-three-repo </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "app create runs without a terminal" 0 "$rc"
site=$(cat "$INSTALL_DIR/apps/app-three/site.caddy" 2>/dev/null || true)
assert_contains "site.caddy has the host" "$site" "app-three.test {"
assert_contains "site.caddy proxies to the aliased service, streaming" "$site" "reverse_proxy app-three-web:80 {
		import sse"
assert_contains "site.caddy imports the security headers" "$site" "import security-headers"
server=$(cat "$INSTALL_DIR/apps/app-three/compose.server.yml" 2>/dev/null || true)
assert_contains "compose.server.yml aliases the service on the proxy network" "$server" "aliases:
          - app-three-web"
# shellcheck disable=SC2016 # the literal compose interpolation
assert_contains "compose.server.yml names the proxy network by MD_WEB_NETWORK" "$server" 'name: ${MD_WEB_NETWORK:-web}'
assert_not_contains "compose.server.yml has no traefik labels" "${server,,}" "traefik"

out=$(app deploy app-three 2>&1) && rc=0 || rc=$?
assert_eq "app deploy succeeds" 0 "$rc"
assert_contains "app deploy reloads the proxy" "$out" "Caddy reloaded."
assert_eq "app-three.test serves after the deploy" app-three "$(serves app-three.test)"
assert_eq "Caddy was reloaded, not restarted" "$caddy_started" "$(started_at)"

out=$(app proxy status 2>&1) && rc=0 || rc=$?
assert_eq "app proxy status succeeds" 0 "$rc"
assert_contains "status lists the app's host with the local CA's certificate expiry" \
  "$(grep '^app-three ' <<< "$out")" "GMT (local)"
assert_contains "app detail shows the site.caddy" "$(app detail app-three 2>&1)" "Proxy (site.caddy):"

echo "# a deploy with a broken site.caddy"
cp "$INSTALL_DIR/apps/app-three/site.caddy" /tmp/site.caddy.good
printf 'app-three.test {\n\tnot_a_directive\n}\n' > "$INSTALL_DIR/apps/app-three/site.caddy"
out=$(app deploy app-three 2>&1) && rc=0 || rc=$?
assert_eq "the deploy fails" 1 "$rc"
assert_contains "the deploy prints Caddy's error" "$out" "unrecognized directive: not_a_directive"
assert_eq "app-one keeps serving" app-one "$(serves app-one.test)"
assert_eq "app-three keeps its running route" app-three "$(serves app-three.test)"
cp /tmp/site.caddy.good "$INSTALL_DIR/apps/app-three/site.caddy"

echo "# validate's cross-app checks"
printf 'on_demand_tls {\n\task http://app-two-web/ask\n}\n' > "$INSTALL_DIR/apps/app-two/global.caddy"
out=$(app proxy validate 2>&1) && rc=0 || rc=$?
assert_eq "a second on_demand_tls owner is refused" 1 "$rc"
assert_contains "the refusal names both apps" "$out" "apps app-one app-two: more than one app defines on_demand_tls"
rm "$INSTALL_DIR/apps/app-two/global.caddy"

echo "# app delete"
app down app-three >/dev/null 2>&1 || true
out=$(printf 'y\n' | app delete app-three 2>&1) && rc=0 || rc=$?
assert_eq "app delete succeeds" 0 "$rc"
assert_contains "app delete reloads the proxy" "$out" "Caddy reloaded."
assert_not_contains "the running config has no route for app-three" \
  "$(docker exec "$CADDY" wget -qO- http://127.0.0.1:2019/config/)" "app-three.test"
curl_run --cacert "$ROOT_CA" --resolve "app-three.test:443:$ip" https://app-three.test/ >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "app-three.test is no longer served" 1 "$(( rc != 0 ))"
assert_eq "app-two still serves" app-two "$(serves app-two.test)"
assert_eq "Caddy was never restarted" "$caddy_started" "$(started_at)"

for app in app-one app-two; do "$INSTALL_DIR/bin/app-compose" "$app" down >/dev/null 2>&1 || true; done
(cd "$INSTALL_DIR/caddy" && docker compose down >/dev/null 2>&1) || true

echo "# docker-prune.sh keeps images labelled multi-deploy.keep=true"
# The prune is scoped to this run's label, so nothing outside the test can go.
host_images() { docker images -q | sort -u; }
prune_keep="md-test-prune-keep:$MD_TEST_RUN"
prune_drop="md-test-prune-drop:$MD_TEST_RUN"
images_before=$(host_images)
printf 'FROM %s
' "$NGINX_IMAGE" | docker build -q --label "$MD_TEST_LABEL"   --label multi-deploy.keep=true -t "$prune_keep" - >/dev/null
printf 'FROM %s
' "$NGINX_IMAGE" | docker build -q --label "$MD_TEST_LABEL" -t "$prune_drop" - >/dev/null
keep_id=$(docker image inspect -f '{{.Id}}' "$prune_keep")
drop_id=$(docker image inspect -f '{{.Id}}' "$prune_drop")
sleep 1
out=$(PRUNE_LABEL_SCOPE="$MD_TEST_LABEL" PRUNE_LOCK_FILE=/tmp/md-test-prune.lock   /src/bin/docker-prune.sh --days 0 2>&1) && rc=0 || rc=$?
assert_eq "docker-prune.sh succeeds" 0 "$rc"
assert_contains "the build cache prune is skipped in scoped mode" "$out" "build cache prune skipped"
docker image inspect "$keep_id" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "the image labelled multi-deploy.keep=true survives" 0 "$rc"
docker image inspect "$drop_id" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "the unlabelled image is pruned" 1 "$(( rc != 0 ))"
docker rmi -f "$keep_id" >/dev/null 2>&1 || true
assert_eq "the host image set is otherwise unchanged" "$images_before" "$(host_images)"

finish "e2e"
