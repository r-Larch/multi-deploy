#!/usr/bin/env bash
# End-to-end gate: setup.sh installs from a snapshot of this checkout, starts Caddy (local_certs,
# no host ports) on a dedicated test network, and two sample apps are served over TLS. Then a v1
# install (the 1.1.0 tag) with Traefik and two apps is upgraded and cut over to Caddy.
# The harness runs in a container with the host Docker socket. Each INSTALL_DIR lives in a labelled
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
V1_REF=${MD_TEST_V1_REF:-1.1.0}
VOLUME="md-test-$RUN_ID"
V1_VOLUME="md-test-v1-$RUN_ID"
V1_DIR=$(mktemp -d)

trap 'remove_labelled "$LABEL"; rm -rf "$V1_DIR"' EXIT

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "ERROR: network $NETWORK already exists; remove it or set MD_TEST_NETWORK." >&2
  exit 1
fi
if docker inspect multi-deploy-caddy >/dev/null 2>&1; then
  echo "ERROR: a container named multi-deploy-caddy already exists on this Docker host." >&2
  exit 1
fi
# LF as in the repository: the 1.1.0 tree predates .gitattributes, and autocrlf would apply.
git -C "$(host_path "$ROOT_DIR")" -c core.autocrlf=false -c core.eol=lf archive --format=tar -o "$(host_path "$V1_DIR")/v1.tar" "$V1_REF"

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
  -v "$(host_path "$V1_DIR"):/v1:ro" \
  -e MD_TEST_RUN="$RUN_ID" -e MD_TEST_LABEL="$LABEL" \
  -e MD_TEST_VOLUME="$VOLUME" -e MD_TEST_MOUNT="$MOUNT" \
  -e MD_TEST_V1_VOLUME="$V1_VOLUME" -e MD_TEST_V1_MOUNT="$V1_MOUNT" \
  -e MD_TEST_NETWORK="$NETWORK" -e MD_TEST_SUBNET="$SUBNET" -e MD_TEST_ALT_SUBNET="$ALT_SUBNET" \
  -e CADDY_IMAGE -e NGINX_IMAGE -e CURL_IMAGE -e TRAEFIK_IMAGE \
  "$TEST_IMAGE" bash /src/tests/e2e/harness.sh
