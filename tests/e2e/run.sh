#!/usr/bin/env bash
# End-to-end gate: setup.sh installs from a snapshot of this checkout, starts Caddy (local_certs,
# no host ports) on a dedicated test network, and two sample apps are served over TLS. Then a v1
# install (the 1.1.0 tag) with Traefik and two apps is upgraded and cut over to Caddy.
# With --cms <repo> it runs only the CMS scenario instead (tests/e2e/cms.sh): the CMS repository's
# HEAD as a multi-deploy app behind the shared Caddy, driven by that repository's smoke test. It
# needs GITHUB_PACKAGES_TOKEN and SIXLABORS_LICENSE_KEY in the environment or in the repository's .env.
# The harness runs in a container with the host Docker socket. Each INSTALL_DIR lives in a labelled
# named volume mounted at the daemon's own path for it, so the relative bind mounts that compose
# resolves inside the harness name the same directory for the daemon.
# Everything created carries the label multi-deploy.test=<run> and is removed on exit.
# Usage: ./tests/e2e/run.sh [--cms <path to the CMS repository>]
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

CMS_REPO=""
if [[ "${1:-}" == --cms ]]; then
  CMS_REPO=${2:?usage: $0 [--cms <path to the CMS repository>]}
elif (( $# > 0 )); then
  echo "usage: $0 [--cms <path to the CMS repository>]" >&2
  exit 2
fi

RUN_ID="e2e-$(date +%s)-$$"
LABEL="multi-deploy.test=$RUN_ID"
NETWORK=${MD_TEST_NETWORK:-md-test-web}
SUBNET=${MD_TEST_SUBNET:-172.31.250.0/24}
ALT_SUBNET=${MD_TEST_ALT_SUBNET:-172.31.251.0/24}
V1_REF=${MD_TEST_V1_REF:-1.1.0}
# The CMS app's name is its compose project's name; never cms, the name of a developer's own stack.
CMS_APP=${MD_TEST_CMS_APP:-mde2ecms}
CMS_PROXY_SUBNET=${MD_TEST_CMS_PROXY_SUBNET:-10.30.250.0/24}
VOLUME="md-test-$RUN_ID"
V1_VOLUME="md-test-v1-$RUN_ID"
WORK_DIR=$(mktemp -d)

# Leftovers of the CMS app: its compose project and the builder's sandboxes (label cms.builder).
cms_teardown() {
  (cd "$WORK_DIR" && docker compose -p "$CMS_APP" down -v --remove-orphans >/dev/null 2>&1) || true
  docker ps -aq --filter "label=cms.builder=$CMS_APP-build" | xargs -r docker rm -f >/dev/null
  docker volume ls -q --filter "label=cms.builder=$CMS_APP-build" | xargs -r docker volume rm >/dev/null
}
cms_leftovers() {
  docker ps -a --format '{{.Names}}' | grep "^$CMS_APP-" || true
  docker volume ls --format '{{.Name}}' | grep -E "^${CMS_APP}[_-]" || true
  docker network ls --format '{{.Name}}' | grep -E "^${CMS_APP}[_-]" || true
}
cleanup() {
  [[ -z "$CMS_REPO" ]] || cms_teardown
  remove_labelled "$LABEL"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "ERROR: network $NETWORK already exists; remove it or set MD_TEST_NETWORK." >&2
  exit 1
fi
if docker inspect multi-deploy-caddy >/dev/null 2>&1; then
  echo "ERROR: a container named multi-deploy-caddy already exists on this Docker host." >&2
  exit 1
fi

if [[ -n "$CMS_REPO" ]]; then
  if [[ -n "$(cms_leftovers)" ]]; then
    echo "ERROR: resources named $CMS_APP-* or ${CMS_APP}_* exist; remove them or set MD_TEST_CMS_APP." >&2
    exit 1
  fi
  # from_dotenv <file> <key>: the key's last value in the file, unquoted, as the CMS's smoke.sh reads it.
  from_dotenv() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n 1 | sed "s/^'\(.*\)'$/\1/; s/^\"\(.*\)\"$/\1/"
  }
  # The repository's .env, or the main checkout's when the path is a git worktree.
  main_env="$(git -C "$CMS_REPO" rev-parse --path-format=absolute --git-common-dir)/../.env"
  for key in GITHUB_PACKAGES_TOKEN SIXLABORS_LICENSE_KEY; do
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(from_dotenv "$CMS_REPO/.env" "$key")"
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(from_dotenv "$main_env" "$key")"
    [[ -n "${!key:-}" ]] || { echo "ERROR: $key is not set (environment or $CMS_REPO/.env)." >&2; exit 1; }
    export "${key?}"
  done
  git -C "$CMS_REPO" -c core.autocrlf=false -c core.eol=lf archive --format=tar -o "$(host_path "$WORK_DIR")/cms.tar" HEAD

  build_test_image
  for image in "$CADDY_IMAGE" "$CURL_IMAGE"; do
    docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null
  done
  docker volume create --label "$LABEL" "$VOLUME" >/dev/null
  MOUNT=$(docker volume inspect -f '{{.Mountpoint}}' "$VOLUME")

  rc=0
  docker run --rm --label "$LABEL" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$VOLUME:$MOUNT" \
    -v "$(host_path "$ROOT_DIR"):/src:ro" \
    -v "$(host_path "$WORK_DIR"):/cms:ro" \
    -e MD_TEST_RUN="$RUN_ID" -e MD_TEST_LABEL="$LABEL" \
    -e MD_TEST_VOLUME="$VOLUME" -e MD_TEST_MOUNT="$MOUNT" \
    -e MD_TEST_NETWORK="$NETWORK" -e MD_TEST_SUBNET="$SUBNET" \
    -e MD_TEST_CMS_APP="$CMS_APP" -e MD_TEST_CMS_PROXY_SUBNET="$CMS_PROXY_SUBNET" \
    -e CADDY_IMAGE -e CURL_IMAGE -e GITHUB_PACKAGES_TOKEN -e SIXLABORS_LICENSE_KEY \
    "$TEST_IMAGE" bash /src/tests/e2e/cms.sh || rc=$?

  cleanup
  trap - EXIT
  left=$(cms_leftovers; docker ps -aq --filter "label=$LABEL"; docker volume ls -q --filter "label=$LABEL"; docker network ls -q --filter "label=$LABEL")
  if [[ -n "$left" ]]; then
    echo "FAIL - the run left resources behind:"
    printf '%s\n' "$left" | sed 's/^/       /'
    exit 1
  fi
  echo "ok   - no $CMS_APP-* or ${CMS_APP}_* containers, volumes or networks and nothing labelled $LABEL remain"
  exit "$rc"
fi

# LF as in the repository: the 1.1.0 tree predates .gitattributes, and autocrlf would apply.
git -C "$(host_path "$ROOT_DIR")" -c core.autocrlf=false -c core.eol=lf archive --format=tar -o "$(host_path "$WORK_DIR")/v1.tar" "$V1_REF"

build_test_image
for image in "$CADDY_IMAGE" "$NGINX_IMAGE" "$PYTHON_IMAGE" "$CURL_IMAGE" "$TRAEFIK_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null
done

docker volume create --label "$LABEL" "$VOLUME" >/dev/null
docker volume create --label "$LABEL" "$V1_VOLUME" >/dev/null
MOUNT=$(docker volume inspect -f '{{.Mountpoint}}' "$VOLUME")
V1_MOUNT=$(docker volume inspect -f '{{.Mountpoint}}' "$V1_VOLUME")

docker run --rm --label "$LABEL" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$VOLUME:$MOUNT" -v "$V1_VOLUME:$V1_MOUNT" \
  -v "$(host_path "$ROOT_DIR"):/src:ro" \
  -v "$(host_path "$WORK_DIR"):/v1:ro" \
  -e MD_TEST_RUN="$RUN_ID" -e MD_TEST_LABEL="$LABEL" \
  -e MD_TEST_VOLUME="$VOLUME" -e MD_TEST_MOUNT="$MOUNT" \
  -e MD_TEST_V1_VOLUME="$V1_VOLUME" -e MD_TEST_V1_MOUNT="$V1_MOUNT" \
  -e MD_TEST_NETWORK="$NETWORK" -e MD_TEST_SUBNET="$SUBNET" -e MD_TEST_ALT_SUBNET="$ALT_SUBNET" \
  -e CADDY_IMAGE -e CURL_IMAGE -e NGINX_IMAGE -e TRAEFIK_IMAGE \
  "$TEST_IMAGE" bash /src/tests/e2e/harness.sh
