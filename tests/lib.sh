# shellcheck shell=bash
# Host-side helpers for tests/run.sh and tests/e2e/run.sh (Git Bash on Windows, or bash on Linux).
# Everything Linux-specific runs in pinned containers.

# Git Bash would rewrite /container/paths passed to docker.
export MSYS_NO_PATHCONV=1

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TESTS_DIR/.." && pwd)
export ROOT_DIR

TEST_IMAGE=multi-deploy-test:28.3.2-3
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.10.0
CADDY_IMAGE=caddy:2.11.9-alpine
NGINX_IMAGE=nginx:1.27-alpine
PYTHON_IMAGE=python:3.13-alpine
CURL_IMAGE=curlimages/curl:8.11.1
# The image traefik/docker-compose.yml of the v1 tag pins.
TRAEFIK_IMAGE=traefik:v3.7.5
export TEST_IMAGE SHELLCHECK_IMAGE CADDY_IMAGE NGINX_IMAGE PYTHON_IMAGE CURL_IMAGE TRAEFIK_IMAGE

# Path of a host directory as the Docker daemon understands it (P:/… on Docker Desktop).
host_path() {
  if (cd "$1" && pwd -W) >/dev/null 2>&1; then (cd "$1" && pwd -W); else (cd "$1" && pwd); fi
}

# Removes the containers, images, networks and volumes carrying the label (key=value).
remove_labelled() {
  local label="$1"
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null
  docker images -q --filter "label=$label" | sort -u | xargs -r docker rmi -f >/dev/null
  docker network ls -q --filter "label=$label" | xargs -r docker network rm >/dev/null
  docker volume ls -q --filter "label=$label" | xargs -r docker volume rm >/dev/null
}

build_test_image() {
  docker build -q -t "$TEST_IMAGE" "$(host_path "$TESTS_DIR/docker")" >/dev/null
}
