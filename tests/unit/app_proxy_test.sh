#!/usr/bin/env bash
# Unit tests for bin/app-proxy: multi-deploy's cross-app checks and the validate/reload contract,
# against a stub `docker`. Runs inside the test image (tests/docker), without a Docker socket.
set -euo pipefail

SRC=${SRC:-/src}
# shellcheck source=tests/assert.sh
source "$SRC/tests/assert.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export STUB="$WORK/stub" INSTALL_DIR="$WORK/install"
mkdir -p "$WORK/bin" "$INSTALL_DIR"
cp -r "$SRC/bin" "$INSTALL_DIR/bin"

# Stub state in $STUB: calls logs every invocation, stopped makes the Caddy container not running,
# fail_<subcommand> makes `caddy <subcommand>` print the file and exit 1, traefik holds the names of
# running Traefik containers, run_out is what `docker run` prints.
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB/calls"
case "$1" in
  inspect) [[ -f "$STUB/stopped" ]] && echo false || echo true ;;
  exec) if [[ -f "$STUB/fail_$4" ]]; then cat "$STUB/fail_$4"; exit 1; fi ;;
  ps) if [[ "$*" == *com.docker.compose.project=traefik* ]]; then cat "$STUB/traefik" 2>/dev/null || true; fi ;;
  run) cat "$STUB/run_out" 2>/dev/null || true ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

reset() {
  rm -rf "$INSTALL_DIR/apps" "$STUB"
  mkdir -p "$INSTALL_DIR/apps" "$STUB"
  : > "$STUB/calls"
}
# put <app> <file> <content>: content with \n and \t escapes.
put() { mkdir -p "$INSTALL_DIR/apps/$1"; printf '%b' "$3" > "$INSTALL_DIR/apps/$1/$2"; }
proxy() { rc=0; out=$("$INSTALL_DIR/bin/app-proxy" "$@" 2>&1) || rc=$?; }

ODT='on_demand_tls {\n\task http://alpha-web/ask\n}\n'
CATCH_ALL='https:// {\n\ttls {\n\t\ton_demand\n\t}\n\treverse_proxy alpha-web:80\n}\n'
SITE_A='alpha.test {\n\treverse_proxy alpha-web:80\n}\n'
SITE_B='# beta\nbeta.test, www.beta.test {\n\timport security-headers\n\treverse_proxy beta-app:8080 {\n\t\timport sse\n\t}\n}\n(beta-cors) {\n\theader X-Beta 1\n}\n'
VALIDATE_CALL="docker exec multi-deploy-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
RELOAD_CALL="docker exec multi-deploy-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile"

echo "# app-proxy validate: accepted configs"

reset
put alpha site.caddy "$SITE_A$CATCH_ALL"; put alpha global.caddy "$ODT"; put beta site.caddy "$SITE_B"
proxy validate
assert_eq "two apps, catch-all owned by the on_demand_tls app, prefixed snippet: valid" 0 "$rc"
assert_contains "Caddy validates the root Caddyfile in the container" "$(cat "$STUB/calls")" "$VALIDATE_CALL"

reset
put alpha site.caddy '# log every request\nalpha.test {\n\trespond "ok" # log\n\tlog_skip /health\n}\n'
proxy validate
assert_eq "log in comments and log_* directives are not a log directive" 0 "$rc"

echo "# app-proxy validate: (a) global.caddy holds only on_demand_tls, owned by one app"

reset
put alpha site.caddy "$SITE_A"; put beta site.caddy "$SITE_B"; put beta global.caddy 'grace_period 7s\n'
proxy validate
assert_eq "other global options are refused" 1 "$rc"
assert_contains "the refusal names the app and the option" "$out" "app beta: global.caddy may contain only an on_demand_tls block, found: grace_period"
assert_not_contains "Caddy is not asked once multi-deploy refuses" "$(cat "$STUB/calls")" "caddy validate"

reset
put alpha site.caddy "$SITE_A"; put alpha global.caddy "$ODT"; put beta site.caddy "$SITE_B"; put beta global.caddy "$ODT"
put gamma site.caddy 'gamma.test {\n\treverse_proxy gamma-web:80\n}\n'
proxy validate
assert_eq "two apps defining on_demand_tls are refused" 1 "$rc"
assert_contains "the refusal names both apps" "$out" "apps alpha beta: more than one app defines on_demand_tls"

echo "# app-proxy validate: (b) one catch-all site, in the on_demand_tls app"

reset
put alpha site.caddy "$SITE_A$CATCH_ALL"; put alpha global.caddy "$ODT"
put beta site.caddy 'beta.test, :443 {\n\treverse_proxy beta-app:8080\n}\n'
proxy validate
assert_eq "two apps with a catch-all site are refused" 1 "$rc"
assert_contains "the refusal names both apps" "$out" "apps alpha beta: more than one app defines a catch-all site"

reset
put alpha site.caddy "$SITE_A"; put alpha global.caddy "$ODT"
put beta site.caddy 'http:// {\n\treverse_proxy beta-app:8080\n}\n'
proxy validate
assert_eq "a catch-all site outside the on_demand_tls app is refused" 1 "$rc"
assert_contains "the refusal names the app and the owner" "$out" "app beta: defines a catch-all site but on_demand_tls is owned by alpha"

reset
put beta site.caddy 'https://:443 {\n\treverse_proxy beta-app:8080\n}\n'
proxy validate
assert_eq "a catch-all site without any on_demand_tls owner is refused" 1 "$rc"
assert_contains "the refusal says no app owns on_demand_tls" "$out" "app beta: defines a catch-all site but on_demand_tls is owned by no app"

echo "# app-proxy validate: (c) app snippets are named <app>-…"

reset
put alpha site.caddy "$SITE_A"; put beta site.caddy "$SITE_B(cors) {\n\theader X 1\n}\n(alpha-x) {\n\theader Y 1\n}\n"
proxy validate
assert_eq "unprefixed snippets are refused" 1 "$rc"
assert_contains "the refusal names the app and the snippet" "$out" "app beta: snippet (cors) must be named (beta-…)"
assert_contains "another app's prefix is refused too" "$out" "app beta: snippet (alpha-x) must be named (beta-…)"

echo "# app-proxy validate: (d) no log directive in site.caddy"

reset
put alpha site.caddy "$SITE_A"
put beta site.caddy 'beta.test {\n\thandle {\n\t\tlog {\n\t\t\toutput stdout\n\t\t}\n\t\treverse_proxy beta-app:8080\n\t}\n}\n'
proxy validate
assert_eq "a log directive is refused" 1 "$rc"
assert_contains "the refusal names the app and the line" "$out" "app beta: site.caddy line 3 has a log directive"

echo "# app-proxy validate/reload: Caddy's verdict"

reset
put alpha site.caddy "$SITE_A"
echo '{"level":"error","msg":"adapting config using caddyfile: /etc/caddy/apps/alpha/site.caddy:2: unrecognized directive: nope"}' > "$STUB/fail_validate"
proxy reload
assert_eq "reload stops when Caddy refuses the config" 1 "$rc"
assert_contains "Caddy's error is printed" "$out" "unrecognized directive: nope"
assert_not_contains "reload is not attempted" "$(cat "$STUB/calls")" "caddy reload"

reset
put alpha site.caddy "$SITE_A"
echo 'Error: sending configuration to instance: loading new config: listen tcp :443: bind: address in use' > "$STUB/fail_reload"
proxy reload
assert_eq "a failed caddy reload fails" 1 "$rc"
assert_contains "the reload error is printed" "$out" "Error: sending configuration to instance"
assert_contains "the running config is said to stay" "$out" "Caddy kept its running config."

reset
put alpha site.caddy "$SITE_A"
proxy reload
assert_eq "reload succeeds" 0 "$rc"
assert_contains "Caddy reloads the root Caddyfile in the container" "$(cat "$STUB/calls")" "$RELOAD_CALL"
assert_contains "reload reports success" "$out" "Caddy reloaded."

reset
put alpha site.caddy "$SITE_A"; touch "$STUB/stopped"
proxy reload
assert_eq "reload fails when neither Caddy nor Traefik runs" 1 "$rc"
assert_contains "the missing container is named" "$out" "multi-deploy-caddy is not running"

echo "# app-proxy before the cutover: Traefik serves, Caddy is not running"

reset
put alpha site.caddy "$SITE_A"; touch "$STUB/stopped"; echo traefik > "$STUB/traefik"
proxy reload
assert_eq "reload succeeds while Traefik serves" 0 "$rc"
assert_eq "reload says why it skipped, in one line" \
  "Proxy not migrated to Caddy yet: Traefik (traefik) is serving, so the Caddy reload was skipped (see $INSTALL_DIR/docs/UPGRADING.md)." "$out"
assert_not_contains "Caddy is not asked" "$(cat "$STUB/calls")" "caddy "

reset
put alpha site.caddy "$SITE_A"; touch "$STUB/stopped"
proxy validate
assert_eq "validate works without the Caddy container" 0 "$rc"
assert_contains "validate says how" "$out" "Caddy validates the files in a throwaway container"
assert_contains "Caddy validates in a throwaway container with the install's files" "$(cat "$STUB/calls")" \
  "-v $INSTALL_DIR/apps:/etc/caddy/apps:ro caddy:2.11.9-alpine caddy validate --config /etc/caddy/Caddyfile"

echo "# app-proxy cutover: preflight"

reset
mkdir -p "$INSTALL_DIR/traefik"; touch "$INSTALL_DIR/traefik/docker-compose.yml" "$INSTALL_DIR/traefik/.env"
put alpha site.caddy "$SITE_A"; put beta site.caddy "$SITE_B"; touch "$STUB/stopped"
echo "ok alpha-web:80" > "$STUB/run_out"
proxy cutover
assert_eq "cutover without Traefik is refused" 1 "$rc"
assert_contains "the preflight names it" "$out" "FAIL Traefik is not running: nothing to cut over"
assert_contains "an upstream that resolves is listed" "$out" "ok   upstream alpha-web:80 resolves"
assert_contains "an upstream that does not resolve fails" "$out" "FAIL upstream beta-app:8080 does not resolve"
assert_contains "caddy/.env without an email fails" "$out" "FAIL caddy/.env has no ACME_EMAIL"
assert_contains "nothing changes after a failed preflight" "$out" "Preflight failed: nothing was changed."
assert_not_contains "Traefik is not stopped" "$(cat "$STUB/calls")" "compose down"

echo "# app-proxy cleanup-traefik"

reset
echo traefik > "$STUB/traefik"
proxy cleanup-traefik
assert_eq "cleanup-traefik while Traefik runs is refused" 1 "$rc"
assert_contains "the refusal says why" "$out" "needs Caddy running and Traefik stopped"
rm "$STUB/traefik"; touch "$STUB/stopped"
proxy cleanup-traefik
assert_eq "cleanup-traefik while Caddy is stopped is refused" 1 "$rc"

reset
mkdir -p "$INSTALL_DIR/traefik/letsencrypt"; echo '{}' > "$INSTALL_DIR/traefik/letsencrypt/acme.json"
proxy cleanup-traefik
assert_eq "cleanup-traefik succeeds with Caddy running and Traefik stopped" 0 "$rc"
assert_cmd "traefik/letsencrypt is removed" test ! -e "$INSTALL_DIR/traefik/letsencrypt"
backups=("$INSTALL_DIR"/backups/traefik-letsencrypt-*.tar.gz)
backup=${backups[0]}
assert_eq "the backup holds acme.json" "letsencrypt/acme.json" "$(tar -tzf "$backup" 2>/dev/null | grep acme.json)"
assert_eq "the backup is private" 600 "$(stat -c %a "$backup" 2>/dev/null)"
assert_cmd "the traefik/ files stay" test -f "$INSTALL_DIR/traefik/docker-compose.yml"

finish "unit app-proxy"
