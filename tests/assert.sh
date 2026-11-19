# shellcheck shell=bash
# Minimal TAP-like assertions shared by the unit tests and the e2e harness.

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }

not_ok() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/       /'; fi
}

assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1" "expected [$2] got [$3]"; fi
}

assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else not_ok "$1" "missing [$3] in:
${2:0:1500}"; fi
}

assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else not_ok "$1" "unexpected [$3] in:
${2:0:1500}"; fi
}

# assert_cmd <description> <command...>: passes when the command exits 0.
assert_cmd() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else not_ok "$desc" "command failed: $*"; fi
}

# finish <suite>: prints the summary line and returns non-zero when anything failed.
finish() {
  echo "# $1: $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
}
