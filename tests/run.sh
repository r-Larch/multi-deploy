#!/usr/bin/env bash
# Unit gate: shellcheck, setup.sh unit tests and Caddyfile validation, each in a pinned container.
# Usage: ./tests/run.sh   (from Git Bash on Windows, or bash on Linux; needs Docker)
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/assert.sh
source "$TESTS_DIR/assert.sh"

RUN_LABEL="multi-deploy.test=unit-$$"
SRC=$(host_path "$ROOT_DIR")

MIGRATED=$(mktemp -d)
trap 'remove_labelled "$RUN_LABEL"; rm -rf "$MIGRATED"' EXIT

echo "# shellcheck ($SHELLCHECK_IMAGE)"
cd "$ROOT_DIR"
scripts=(bin/* setup.sh tests/*.sh tests/unit/*.sh tests/e2e/*.sh)
if out=$(docker run --rm --label "$RUN_LABEL" -v "$SRC:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x "${scripts[@]}" 2>&1); then
  ok "shellcheck clean: ${scripts[*]}"
else
  not_ok "shellcheck" "$out"
fi

build_test_image
for t in tests/unit/*_test.sh; do
  if docker run --rm --label "$RUN_LABEL" -v "$SRC:/src:ro" "$TEST_IMAGE" bash "/src/$t"; then
    ok "unit tests $t"
  else
    not_ok "unit tests $t"
  fi
done

echo "# Caddyfile ($CADDY_IMAGE)"
caddy_run() {
  docker run --rm --label "$RUN_LABEL" -e ACME_EMAIL=unit@example.test \
    -v "$SRC/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$SRC/caddy/snippets:/etc/caddy/snippets:ro" \
    "$@"
}

out=$(caddy_run --tmpfs /etc/caddy/apps "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile 2>&1) && rc=0 || rc=$?
assert_eq "root Caddyfile with no apps is valid" 0 "$rc"
assert_contains "app imports matching no files are accepted" "$out" "No files matching import glob pattern"

apps="-v $SRC/tests/fixtures/apps:/etc/caddy/apps:ro"
# shellcheck disable=SC2086 # $apps is two words on purpose
out=$(caddy_run $apps "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile 2>&1) && rc=0 || rc=$?
assert_eq "root Caddyfile with two apps is valid" 0 "$rc"

# shellcheck disable=SC2086
json=$(caddy_run $apps "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null)
assert_contains "global.caddy of an app lands in the global options" "$json" '"on_demand":{"permission":{"endpoint":"http://app-one-web/ask"'
assert_contains "site.caddy of app-one is served" "$json" '"app-one.test"'
assert_contains "site.caddy of app-two is served" "$json" '"app-two.test"'
assert_contains "sse snippet flushes immediately" "$json" '"flush_interval":-1'
assert_contains "security-headers snippet sets HSTS" "$json" '"max-age=31536000; includeSubDomains; preload"'
assert_contains "ACME email comes from ACME_EMAIL" "$json" '"email":"unit@example.test"'
assert_contains "access logging is on for every site" "$json" '"logs":{"trace":true}'
assert_not_contains "no server timeouts are set" "$json" '_timeout"'

# The golden site.caddy files of tests/fixtures/migrate, served together as one migrated server.
for dir in tests/fixtures/migrate/*/; do
  mkdir -p "$MIGRATED/$(basename "$dir")"
  cp "$dir/expected.site.caddy" "$MIGRATED/$(basename "$dir")/site.caddy"
done
migrated="-v $(host_path "$MIGRATED"):/etc/caddy/apps:ro"
# shellcheck disable=SC2086 # $migrated is two words on purpose
out=$(caddy_run $migrated "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile 2>&1) && rc=0 || rc=$?
assert_eq "the six migrated site.caddy files are valid together" 0 "$rc"
# shellcheck disable=SC2086
json=$(caddy_run $migrated "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null)
assert_contains "the compress snippet encodes html" "$json" '"Content-Type":["text/html*"'
assert_not_contains "the compress snippet leaves text/event-stream out" "$json" 'text/event-stream'
assert_not_contains "the compress snippet does not match every text type" "$json" '"text/*"'

finish "tests/run.sh"
