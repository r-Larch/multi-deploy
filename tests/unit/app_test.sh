#!/usr/bin/env bash
# Unit tests for bin/app and bin/lib-app against stub `docker` and `systemctl`.
# Runs inside the test image (tests/docker), without a Docker socket.
set -euo pipefail

SRC=${SRC:-/src}
# shellcheck source=tests/assert.sh
source "$SRC/tests/assert.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export STUB="$WORK/stub" INSTALL_DIR="$WORK/install"
mkdir -p "$WORK/bin" "$STUB" "$INSTALL_DIR/apps" "$INSTALL_DIR/caddy"
cp -r "$SRC/bin" "$INSTALL_DIR/bin"
: > "$STUB/calls"

cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB/calls"
[[ "$1" != inspect ]] || echo true
exit 0
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/docker" "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
unset MD_WEB_NETWORK

echo "# app list: app.env keys stay with their app"

# app-a sorts first; its ENV_FILE and REPO must not carry over to app-b.
mkdir -p "$INSTALL_DIR/apps/app-a" "$INSTALL_DIR/apps/app-b"
printf 'NAME=app-a\nREPO=git@example.test:a.git\nBRANCH=main\nCOMPOSE_FILE=compose.yml\nENV_FILE=.env\n' > "$INSTALL_DIR/apps/app-a/app.env"
: > "$INSTALL_DIR/apps/app-a/.env"
printf 'NAME=app-b\nCOMPOSE_FILE=compose.yml\n' > "$INSTALL_DIR/apps/app-b/app.env"

out=$("$INSTALL_DIR/bin/app" list 2>&1)
calls=$(cat "$STUB/calls")
assert_contains "app-a's compose gets its env file" "$calls" "--project-name app-a --env-file $INSTALL_DIR/apps/app-a/.env"
assert_not_contains "app-a's ENV_FILE does not reach app-b" "$out" "app-b/.env"
assert_not_contains "app-b's compose has no env file" "$(grep -- '--project-name app-b' <<< "$calls")" "--env-file"
assert_eq "app-b is listed as a static app (REPO does not leak)" "n/a" "$(awk '$1 == "app-b" { print $2 }' <<< "$out")"
assert_eq "app-a is listed as a git app" "off" "$(awk '$1 == "app-a" { print $2 }' <<< "$out")"

echo "# lib-app: proxy network name"

network() { bash -c 'source "$INSTALL_DIR/bin/lib-app"; echo "$MD_WEB_NETWORK"'; }
assert_eq "defaults to web without caddy/.env" "web" "$(network)"
printf 'ACME_EMAIL=a@example.test\nMD_WEB_NETWORK=md-x\n' > "$INSTALL_DIR/caddy/.env"
assert_eq "is read from caddy/.env" "md-x" "$(network)"
assert_eq "the environment wins over caddy/.env" "md-y" "$(MD_WEB_NETWORK=md-y network)"

echo "# app delete stops the stack before removing the app"

: > "$STUB/calls"
mkdir -p "$INSTALL_DIR/apps/app-del"
printf 'NAME=app-del\nCOMPOSE_FILE=compose.yml\n' > "$INSTALL_DIR/apps/app-del/app.env"
out=$(printf 'n\n' | "$INSTALL_DIR/bin/app" delete app-del 2>&1)
assert_contains "app delete asks first" "$out" "Aborted"
assert_eq "an aborted delete runs no compose command" "" "$(grep -- '--project-name app-del' "$STUB/calls" || true)"
out=$(printf 'y\n' | "$INSTALL_DIR/bin/app" delete app-del 2>&1) && rc=0 || rc=$?
assert_eq "app delete succeeds" 0 "$rc"
assert_contains "app delete runs docker compose down on the app's stack" "$(cat "$STUB/calls")" \
  "docker compose --project-name app-del -f $INSTALL_DIR/apps/app-del/compose.yml down"
assert_not_contains "app delete keeps the volumes" "$(grep -- ' down' "$STUB/calls")" "-v"
assert_cmd "app delete removes the app directory" test ! -e "$INSTALL_DIR/apps/app-del"
assert_contains "app delete reloads the proxy" "$(cat "$STUB/calls")" "caddy reload"

echo "# lib-app: default_read answers from the environment"

assert_eq "a set answer variable skips the prompt" "from-env" \
  "$(ANSWER=from-env bash -c 'source "$INSTALL_DIR/bin/lib-app"; default_read "Q" "dflt" ANSWER' </dev/null)"
assert_eq "an unset answer variable falls back to the default" "dflt" \
  "$(bash -c 'source "$INSTALL_DIR/bin/lib-app"; default_read "Q" "dflt" ANSWER' </dev/null)"

finish "unit app"
