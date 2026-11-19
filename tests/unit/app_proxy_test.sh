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
# fail_<subcommand> makes `caddy <subcommand>` print the file and exit 1.
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB/calls"
case "$1" in
  inspect) [[ -f "$STUB/stopped" ]] && echo false || echo true ;;
  exec) if [[ -f "$STUB/fail_$4" ]]; then cat "$STUB/fail_$4"; exit 1; fi ;;
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
assert_eq "reload fails when the Caddy container is not running" 1 "$rc"
assert_contains "the missing container is named" "$out" "multi-deploy-caddy is not running"

finish "unit app-proxy"
