#!/usr/bin/env bash
# End-to-end gate: setup.sh installs from a snapshot of this checkout, starts Caddy (local_certs,
# no host ports) on a dedicated test network, and two sample apps are served over TLS.
# The harness runs in a container with the host Docker socket. INSTALL_DIR lives in a labelled
# named volume mounted at the daemon's own path for it, so the relative bind mounts that compose
# resolves inside the harness name the same directory for the daemon.
# Everything created carries the label multi-deploy.test=<run> and is removed on exit.
# Usage: ./tests/e2e/run.sh
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

RUN_ID="e2e-$(date +%s)-$$"
LABEL="multi-deploy.test=$RUN_ID"
NETWORK=${MD_TEST_NETWORK:-md-test-web}
SUBNET=${MD_TEST_SUBNET:-172.31.250.0/24}
ALT_SUBNET=${MD_TEST_ALT_SUBNET:-172.31.251.0/24}
VOLUME="md-test-$RUN_ID"

trap 'remove_labelled "$LABEL"' EXIT

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "ERROR: network $NETWORK already exists; remove it or set MD_TEST_NETWORK." >&2
  exit 1
fi
if docker inspect multi-deploy-caddy >/dev/null 2>&1; then
  echo "ERROR: a container named multi-deploy-caddy already exists on this Docker host." >&2
  exit 1
fi

build_test_image
for image in "$CADDY_IMAGE" "$NGINX_IMAGE" "$CURL_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null
done

docker volume create --label "$LABEL" "$VOLUME" >/dev/null
MOUNT=$(docker volume inspect -f '{{.Mountpoint}}' "$VOLUME")

docker run --rm --label "$LABEL" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$VOLUME:$MOUNT" \
  -v "$(host_path "$ROOT_DIR"):/src:ro" \
  -e MD_TEST_RUN="$RUN_ID" -e MD_TEST_LABEL="$LABEL" \
  -e MD_TEST_VOLUME="$VOLUME" -e MD_TEST_MOUNT="$MOUNT" \
  -e MD_TEST_NETWORK="$NETWORK" -e MD_TEST_SUBNET="$SUBNET" -e MD_TEST_ALT_SUBNET="$ALT_SUBNET" \
  -e CADDY_IMAGE -e NGINX_IMAGE -e CURL_IMAGE \
  "$TEST_IMAGE" bash /src/tests/e2e/harness.sh
