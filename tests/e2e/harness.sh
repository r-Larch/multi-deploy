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
rsync -a --exclude .git --exclude .claude --exclude brief-u2.md --exclude .commitmsg /src/ /tmp/src/
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
out=$(docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile 2>&1) && rc=0 || rc=$?
assert_eq "Caddy reloads with both apps" 0 "$rc"
assert_contains "app global.caddy is applied" "$(docker exec "$CADDY" wget -qO- http://127.0.0.1:2019/config/)" '"grace_period":7000000000'

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

for app in app-one app-two; do "$INSTALL_DIR/bin/app-compose" "$app" down >/dev/null 2>&1 || true; done
(cd "$INSTALL_DIR/caddy" && docker compose down >/dev/null 2>&1) || true

finish "e2e"
