#!/usr/bin/env bash
# Unit tests for setup.sh: its functions run against a stub `docker` that records calls.
# Runs inside the test image (tests/docker), without a Docker socket.
set -euo pipefail

SRC=${SRC:-/src}
# shellcheck source=tests/assert.sh
source "$SRC/tests/assert.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Stub state lives in $STUB: networks/<name> holds a subnet, ps_project_traefik and ps_all
# hold `docker ps` output, calls logs every invocation.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB/calls"
case "$1" in
  network)
    name="${*: -1}"
    case "$2" in
      inspect) [[ -f "$STUB/networks/$name" ]] || exit 1; printf '%s ' "$(cat "$STUB/networks/$name")" ;;
      create)
        subnet=""; prev=""
        for a in "$@"; do [[ "$prev" == --subnet ]] && subnet="$a"; prev="$a"; done
        mkdir -p "$STUB/networks"; echo "$subnet" > "$STUB/networks/$name" ;;
    esac ;;
  ps)
    if [[ "$*" == *com.docker.compose.project=traefik* ]]; then cat "$STUB/ps_project_traefik" 2>/dev/null || true
    else cat "$STUB/ps_all" 2>/dev/null || true; fi ;;
  compose) [[ "$2" == up ]] && touch "$STUB/caddy_running" ;;
  inspect) [[ -f "$STUB/caddy_running" ]] && echo true || echo false ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"

# fresh: new stub state and install dir; the test body then runs in a subshell that sources setup.sh.
fresh() {
  export STUB="$WORK/stub-$1" INSTALL_DIR="$WORK/install-$1"
  rm -rf "$STUB" "$INSTALL_DIR"
  mkdir -p "$STUB" "$INSTALL_DIR/caddy"
  : > "$STUB/calls"
}

load_setup() {
  unset MD_WEB_NETWORK MD_WEB_SUBNET MD_ACME_EMAIL MD_CADDY_IMAGE MD_RESOURCE_LABEL
  export PATH="$WORK/bin:$PATH"
  # shellcheck source=setup.sh
  MD_SETUP_SOURCE_ONLY=1 source "$SRC/setup.sh"
}

echo "# setup.sh: web network"

fresh net-missing
out=$(load_setup; ensure_web_network)
assert_contains "missing network is created with the fixed default subnet" "$(cat "$STUB/calls")" \
  "docker network create --driver bridge --subnet 172.18.0.0/16 web"
assert_eq "create reports the subnet" "Created network web (subnet: 172.18.0.0/16)." "$out"

fresh net-existing
mkdir -p "$STUB/networks"; echo "10.9.0.0/16" > "$STUB/networks/web"
out=$(load_setup; MD_WEB_SUBNET=172.18.0.0/16; ensure_web_network)
assert_not_contains "existing network is not recreated" "$(cat "$STUB/calls")" "network create"
assert_eq "existing network is kept and its subnet printed" "Network web exists, keeping it (subnet: 10.9.0.0/16)." "$out"

fresh net-custom
out=$(load_setup; MD_WEB_NETWORK=md-x; MD_WEB_SUBNET=10.1.2.0/24; MD_RESOURCE_LABEL=multi-deploy.test=u; ensure_web_network)
assert_contains "network name, subnet and label are configurable" "$(cat "$STUB/calls")" \
  "docker network create --driver bridge --subnet 10.1.2.0/24 --label multi-deploy.test=u md-x"

echo "# setup.sh: Traefik detection"

fresh traefik-project
echo "traefik" > "$STUB/ps_project_traefik"
assert_eq "compose project traefik is detected" "traefik" "$(load_setup; running_traefik)"

fresh traefik-image
printf '%s\n' "edge traefik:v3.7.5" "lib docker.io/library/traefik:v3.2" "app nginx:1.27-alpine" "other mytraefik:1" "x traefik-ui:2" > "$STUB/ps_all"
assert_eq "traefik images are detected, look-alikes are not" "edge
lib" "$(load_setup; running_traefik)"

fresh traefik-none
echo "app nginx:1.27-alpine" > "$STUB/ps_all"
assert_eq "no traefik, nothing detected" "" "$(load_setup; running_traefik)"

echo "# setup.sh: proxy start"

fresh proxy-traefik
echo "traefik" > "$STUB/ps_project_traefik"
rc=0; out=$(load_setup; MD_ACME_EMAIL=a@example.test; setup_proxy) || rc=$?
assert_eq "with Traefik running setup_proxy reports the pending migration" 1 "$rc"
assert_not_contains "with Traefik running Caddy is not started" "$(cat "$STUB/calls")" "docker compose up"
assert_not_contains "with Traefik running the network is left alone" "$(cat "$STUB/calls")" "network create"
assert_contains "with Traefik running the migration guide is named" "$out" "docs/UPGRADING.md"
assert_eq "with Traefik running caddy/.env is still written" "a@example.test" \
  "$(sed -n 's/^ACME_EMAIL=//p' "$INSTALL_DIR/caddy/.env")"

fresh proxy-fresh
rc=0; out=$(load_setup; MD_ACME_EMAIL=a@example.test; setup_proxy) || rc=$?
assert_eq "without Traefik setup_proxy succeeds" 0 "$rc"
assert_contains "without Traefik the network is created" "$(cat "$STUB/calls")" "network create"
assert_contains "without Traefik Caddy is started" "$(cat "$STUB/calls")" "docker compose up -d"
assert_contains "Caddy start is confirmed" "$out" "Caddy is running."
assert_cmd "Caddy data directory exists" test -d "$INSTALL_DIR/caddy/data/caddy-data"

echo "# setup.sh: caddy/.env"

fresh env-new
(load_setup; MD_ACME_EMAIL=new@example.test; MD_CADDY_IMAGE=custom/caddy:1; write_caddy_env)
env=$(cat "$INSTALL_DIR/caddy/.env")
assert_contains "new .env has the ACME email" "$env" "ACME_EMAIL=new@example.test"
assert_contains "new .env records the network" "$env" "MD_WEB_NETWORK=web"
assert_contains "new .env records a custom Caddy image" "$env" "MD_CADDY_IMAGE=custom/caddy:1"
assert_eq ".env is private" 600 "$(stat -c %a "$INSTALL_DIR/caddy/.env")"

fresh env-keep
printf 'ACME_EMAIL=old@example.test\nMD_WEB_NETWORK=md-kept\n' > "$INSTALL_DIR/caddy/.env"
(load_setup; write_caddy_env)
env=$(cat "$INSTALL_DIR/caddy/.env")
assert_contains "existing email is kept" "$env" "ACME_EMAIL=old@example.test"
assert_contains "network name is read back from caddy/.env" "$env" "MD_WEB_NETWORK=md-kept"
(load_setup; MD_ACME_EMAIL=new@example.test; write_caddy_env)
assert_eq "MD_ACME_EMAIL overrides the kept email" "ACME_EMAIL=new@example.test" \
  "$(grep '^ACME_EMAIL=' "$INSTALL_DIR/caddy/.env")"

fresh env-missing
rc=0; (load_setup; write_caddy_env) </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "no email and no prompt answer fails" 1 "$rc"

echo "# setup.sh: systemd"

fresh no-systemd
assert_eq "without systemd the units are skipped" "systemd not found: skipped installing the multi-deploy timers." \
  "$(load_setup; install_systemd_units)"

finish "unit setup.sh"
