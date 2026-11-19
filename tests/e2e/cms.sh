#!/usr/bin/env bash
# Runs inside the e2e harness container for `tests/e2e/run.sh --cms <repo>`: the CMS repository (its HEAD
# as /cms/cms.tar) is installed as a multi-deploy app with its kit (deploy/multi-deploy/cms/), behind the
# shared Caddy, and driven by the repository's own smoke test (tests/e2e/smoke.mjs), then removed.
set -euo pipefail

# shellcheck source=tests/assert.sh
source /src/tests/assert.sh

: "${MD_TEST_RUN:?}" "${MD_TEST_LABEL:?}" "${MD_TEST_VOLUME:?}" "${MD_TEST_MOUNT:?}"
: "${MD_TEST_NETWORK:?}" "${MD_TEST_SUBNET:?}" "${CADDY_IMAGE:?}" "${CURL_IMAGE:?}"
: "${MD_TEST_CMS_APP:?}" "${MD_TEST_CMS_PROXY_SUBNET:?}"
: "${GITHUB_PACKAGES_TOKEN:?}" "${SIXLABORS_LICENSE_KEY:?}"

# shellcheck source=tests/e2e/install.sh
source /src/tests/e2e/install.sh

APP=$MD_TEST_CMS_APP
APP_DIR="$INSTALL_DIR/apps/$APP"
HOST=cms.test
RUNNER="md-test-cms-runner-$MD_TEST_RUN"

curl_run() {
  docker run --rm --label "$MD_TEST_LABEL" --network "$MD_WEB_NETWORK" --user 0 \
    -v "$MD_TEST_VOLUME:$MD_TEST_MOUNT:ro" "$CURL_IMAGE" -sS --max-time 10 "$@"
}
# redact <text>: the text with the build secrets masked.
redact() { local t="${1//"$GITHUB_PACKAGES_TOKEN"/***}"; echo "${t//"$SIXLABORS_LICENSE_KEY"/***}"; }
stop() { show "$(redact "$1")"; finish "e2e --cms"; exit 1; }
teardown() {
  docker rm -f "$RUNNER" >/dev/null 2>&1 || true
  "$INSTALL_DIR/bin/app-compose" "$APP" down -v --remove-orphans >/dev/null 2>&1 || true
  (cd "$INSTALL_DIR/caddy" && docker compose down >/dev/null 2>&1) || true
}
trap teardown EXIT

echo "# install"
out=$(run_setup) && rc=0 || rc=$?
assert_eq "setup.sh succeeds" 0 "$rc"
(( rc == 0 )) || stop "$out"
assert_eq "Caddy runs" true "$(caddy_state)"
no_prune "$INSTALL_DIR"

echo "# the CMS repository as app $APP"
mkdir -p /tmp/cms-repo
tar -xf /cms/cms.tar -C /tmp/cms-repo
git -C /tmp/cms-repo init -q -b main
git -C /tmp/cms-repo add -A
git -C /tmp/cms-repo -c user.name=e2e -c user.email=e2e@example.test commit -q -m snapshot
out=$(APP_CREATE_BRANCH=main APP_CREATE_SERVICE=cms-web APP_CREATE_HOST="$HOST" APP_CREATE_PORT=8080 \
  APP_CREATE_SSE=n APP_CREATE_HEADERS=n "$INSTALL_DIR/bin/app" create "$APP" file:///tmp/cms-repo </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "app create succeeds" 0 "$rc"
(( rc == 0 )) || stop "$out"

# The kit, as its README installs it. It is written for the app name cms: its aliases (cms-cms-web,
# cms-cms-edge) and its snippet (cms-internal) carry that prefix, so this copy takes the test app's name.
kit="$APP_DIR/code/deploy/multi-deploy/cms"
cat "$kit/app.env" >> "$APP_DIR/app.env"
cp "$kit/compose.server.yml" "$kit/site.caddy" "$kit/global.caddy" "$APP_DIR/"
sed -i "s/cms-cms-web/$APP-cms-web/g; s/cms-cms-edge/$APP-cms-edge/g; s/cms-internal/$APP-internal/g; s/cms\.example\.com/$HOST/g" \
  "$APP_DIR/compose.server.yml" "$APP_DIR/site.caddy" "$APP_DIR/global.caddy"

# The CMS repository's compose.smoke.yml for this stack: mailpit as the SMTP server and the preview domain;
# the builder's network, sandbox names and image carry the app's name, so they are never another CMS's;
# and the run label on every container, built image, volume and network.
sed -i 's/^      - compose.server.yml$/&\n      - compose.e2e.yml/' "$APP_DIR/compose.yml"
label="multi-deploy.test: \"$MD_TEST_RUN\""
cat > "$APP_DIR/compose.e2e.yml" <<EOF
services:
  cms-web:
    build:
      labels: { $label }
    labels: { $label }
    depends_on:
      mailpit:
        condition: service_healthy
    environment:
      - Edge__PreviewDomain=preview.test
  cms-edge:
    build:
      labels: { $label }
    labels: { $label }
    environment:
      - Edge__PreviewDomain=preview.test
  cms-builder:
    build:
      labels: { $label }
    labels: { $label }
    environment:
      - Builds__Network=$APP-build-net
      - Builds__ResourcePrefix=$APP-build
      - Builds__Image=$APP-build:local
  cms-build-image:
    build:
      labels: { $label }
    image: $APP-build:local
    labels: { $label }
  cms-npm-proxy:
    labels: { $label }
  postgres:
    labels: { $label }
  rustfs:
    labels: { $label }
  mailpit:
    image: axllent/mailpit:v1.34.0
    labels: { $label }
    environment:
      - MP_SMTP_AUTH_ACCEPT_ANY=true
      - MP_SMTP_AUTH_ALLOW_INSECURE=true
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8025/livez"]
      interval: 5s
      timeout: 5s
      retries: 12

volumes:
  pgdata: { labels: { $label } }
  rustfs: { labels: { $label } }
  git: { labels: { $label } }
  npm-cache: { labels: { $label } }
  caddy-data: { labels: { $label } }
  caddy-config: { labels: { $label } }

networks:
  default:
    labels: { $label }
  proxy:
    labels: { $label }
  build:
    name: $APP-build-net
    labels: { $label }
  npm-egress:
    name: $APP-npm-egress
    labels: { $label }
EOF

# OAuth key material, once per run (the CMS repository's tests/e2e/smoke.sh does the same).
certificate() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$APP-$1" -keyout "/tmp/$1.key" -out "/tmp/$1.crt" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "/tmp/$1.key" -in "/tmp/$1.crt" -out "/tmp/$1.pfx" -passout pass: >/dev/null 2>&1
  base64 < "/tmp/$1.pfx" | tr -d '\n'
}
install -m 600 /dev/null "$APP_DIR/.env"
cat > "$APP_DIR/.env" <<EOF
ASPNETCORE_ENVIRONMENT='Production'
GITHUB_PACKAGES_TOKEN='$GITHUB_PACKAGES_TOKEN'
SIXLABORS_LICENSE_KEY='$SIXLABORS_LICENSE_KEY'
POSTGRES_PASSWORD='$(openssl rand -hex 16)'
RUSTFS_ACCESS_KEY='$(openssl rand -hex 10)'
RUSTFS_SECRET_KEY='$(openssl rand -hex 20)'
CMS_ORIGIN='https://$HOST'
CMS_SIGNING_SECRET='$(openssl rand -hex 32)'
CMS_BOOTSTRAP_ADMIN_EMAIL='admin@hotel.test'
CMS_PREVIEW_DOMAIN='preview.test'
CMS_WEB_SUBNET='$MD_TEST_SUBNET'
CMS_PROXY_NETWORK='$MD_TEST_CMS_PROXY_SUBNET'
OPENIDDICT_SIGNING_CERTIFICATE='$(certificate signing)'
OPENIDDICT_ENCRYPTION_CERTIFICATE='$(certificate encryption)'
SMTP_HOST='mailpit'
SMTP_PORT='1025'
SMTP_SECURE_SOCKET_OPTIONS='None'
SMTP_FROM='cms@$HOST'
DOCKER_SOCKET_GID='$(stat -c %g /var/run/docker.sock)'
EOF

echo "# app deploy $APP"
started=$(date +%s)
out=$("$INSTALL_DIR/bin/app" deploy "$APP" 2>&1) && rc=0 || rc=$?
assert_eq "app deploy succeeds ($(( $(date +%s) - started ))s)" 0 "$rc"
(( rc == 0 )) || stop "$(tail -n 60 <<< "$out")"
assert_contains "app deploy reloads the shared Caddy" "$out" "Caddy reloaded."
out=$("$INSTALL_DIR/bin/app-compose" "$APP" up -d --wait --wait-timeout 600 2>&1) && rc=0 || rc=$?
assert_eq "every service is healthy" 0 "$rc"
(( rc == 0 )) || stop "$(tail -n 40 <<< "$out")"
assert_contains "the CMS owns on_demand_tls, asking cms-web" \
  "$(docker exec "$CADDY" wget -qO- http://127.0.0.1:2019/config/)" "\"endpoint\":\"http://$APP-cms-web:8080/internal/tls-allowed\""

echo "# forged X-Forwarded-* headers through the shared Caddy"
ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$MD_WEB_NETWORK\").IPAddress}}" "$CADDY")
discovery() { curl_run --cacert "$ROOT_CA" --resolve "$HOST:443:$ip" "$@" "https://$HOST/.well-known/openid-configuration"; }
plain=$(discovery) || plain=""
forged=$(discovery -H 'X-Forwarded-Host: evil.test' -H 'X-Forwarded-Proto: http') || forged=""
issuer=$(jq -r .issuer <<< "$plain" 2>/dev/null) || issuer=""
forged_issuer=$(jq -r .issuer <<< "$forged" 2>/dev/null) || forged_issuer=""
echo "    | issuer: $issuer; with X-Forwarded-Host: evil.test and X-Forwarded-Proto: http: $forged_issuer"
assert_eq "the issuer is the CMS origin" "https://$HOST/" "$issuer"
assert_eq "forged X-Forwarded-Host and -Proto do not change the issuer" "https://$HOST/" "$forged_issuer"
assert_eq "the discovery document is the same with the forged headers" "$plain" "$forged"
# The CMS pins the issuer but builds the endpoints from the forwarded host it trusts, so a forged
# X-Forwarded-Host alone shows only there.
host_only=$(discovery -H 'X-Forwarded-Host: evil.test') || host_only=""
echo "    | token_endpoint: $(jq -r .token_endpoint <<< "$plain" 2>/dev/null); with X-Forwarded-Host: evil.test only: $(jq -r .token_endpoint <<< "$host_only" 2>/dev/null)"
assert_eq "the discovery document is the same with a forged X-Forwarded-Host alone" "$plain" "$host_only"
assert_not_contains "the discovery document never names the forged host" "$forged$host_only" "evil.test"

echo "# the CMS smoke test (tests/e2e/smoke.mjs) through the shared Caddy"
e2e="$APP_DIR/code/tests/e2e"
docker build -q --label "$MD_TEST_LABEL" -t "md-test-cms-runner:$MD_TEST_RUN" -f "$e2e/runner.Dockerfile" "$e2e" >/dev/null
# The runner reaches the CMS as a client does, through Caddy on the web network; mailpit's API only on
# the app's default network.
docker create --name "$RUNNER" --label "$MD_TEST_LABEL" --network "$MD_WEB_NETWORK" \
  -v "$e2e:/e2e:ro" -v "$MD_TEST_VOLUME:$MD_TEST_MOUNT:ro" \
  -e MAILPIT=http://mailpit:8025 -e ADMIN_EMAIL=admin@hotel.test \
  -e CADDY_HOST="$CADDY" -e CADDY_ROOT_CA="$ROOT_CA" \
  --entrypoint sh "md-test-cms-runner:$MD_TEST_RUN" /e2e/runner.sh >/dev/null
docker network connect "${APP}_default" "$RUNNER"
docker start -a "$RUNNER" 2>&1 | tee /tmp/smoke.log | sed 's/^/    | /' && rc=0 || rc=$?
smoke=$(cat /tmp/smoke.log)
assert_eq "the smoke test exits 0" 0 "$rc"
assert_eq "all 13 steps pass" 13 "$(grep -c '^PASS ' <<< "$smoke" || true)"
assert_contains "on-demand certificates for the preview hosts (step 7)" "$smoke" "PASS 7. "
assert_contains "on-demand certificates for the tenant hosts (step 8)" "$smoke" "PASS 8. "
if (( rc != 0 )); then
  for svc in cms-web cms-edge cms-builder; do
    echo "# docker logs of $svc (last 40 lines)"
    show "$(redact "$("$INSTALL_DIR/bin/app-compose" "$APP" logs --no-color --tail 40 "$svc" 2>&1)")"
  done
fi

finish "e2e --cms"
