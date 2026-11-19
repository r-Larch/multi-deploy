# shellcheck shell=bash
# Sourced by the scenarios that run inside the e2e harness container (harness.sh, cms.sh): the
# install's environment, the git snapshot setup.sh installs from, and Caddy's test-only additions.
# Needs MD_TEST_RUN, MD_TEST_LABEL, MD_TEST_MOUNT, MD_TEST_NETWORK, MD_TEST_SUBNET and CADDY_IMAGE.

export INSTALL_DIR="$MD_TEST_MOUNT/opt/multi-deploy"
export MD_WEB_NETWORK="$MD_TEST_NETWORK" MD_WEB_SUBNET="$MD_TEST_SUBNET"
export MD_RESOURCE_LABEL="$MD_TEST_LABEL" MD_ACME_EMAIL=e2e@example.test
export MD_CADDY_IMAGE="$CADDY_IMAGE" MD_TEST_RUN
export REPO_URL=file:///tmp/src REPO_REF=md-test
# shellcheck disable=SC2034 # used by the scenarios that source this file
CADDY=multi-deploy-caddy
# shellcheck disable=SC2034
ROOT_CA="$INSTALL_DIR/caddy/data/caddy-data/caddy/pki/authorities/local/root.crt"

# setup.sh installs from a git snapshot of the checkout, on a branch, to exercise REPO_REF.
rsync -a --exclude .git --exclude .claude --exclude "brief-u*.md" --exclude fixtures-src --exclude .commitmsg /src/ /tmp/src/
git -C /tmp/src init -q -b md-test
git -C /tmp/src add -A
git -C /tmp/src -c user.name=e2e -c user.email=e2e@example.test commit -q -m snapshot

# Test-only additions next to the installed caddy/compose.yml: no host ports, the run label,
# and local_certs through the Caddyfile's test hook. setup.sh's rsync leaves them in place.
mkdir -p "$INSTALL_DIR/caddy"
cat > "$INSTALL_DIR/caddy/compose.override.yml" <<EOF
services:
  caddy:
    ports: !reset []
    labels:
      multi-deploy.test: "$MD_TEST_RUN"
    volumes:
      - ./test.caddy:/etc/caddy/test.caddy:ro
EOF
printf 'local_certs\nskip_install_trust\n' > "$INSTALL_DIR/caddy/test.caddy"

run_setup() { bash /tmp/src/setup.sh </dev/null 2>&1; }
caddy_state() { local s; s=$(docker inspect -f '{{.State.Running}}' "$CADDY" 2>/dev/null) || s=absent; echo "$s"; }
# docker-prune.sh (run after every deploy) prunes the whole Docker host; the harness swaps in a no-op.
no_prune() { printf '#!/bin/sh\necho "docker-prune.sh skipped in the e2e harness"\n' > "$1/bin/docker-prune.sh"; }
# show <output>: the operator-visible output in the test log.
show() { local l; while IFS= read -r l; do echo "    | $l"; done <<< "$1"; }
