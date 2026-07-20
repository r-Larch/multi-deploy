#!/usr/bin/env bash
set -euo pipefail

# docker-prune.sh [--days N] [--volumes] [--quiet]
#
# Reclaims disk from Docker: dangling + unreferenced images, exited containers,
# the buildx build cache, and unused networks. Everything is age-gated so a
# freshly built layer is never dropped out from under a rolling deploy — only
# objects untouched for longer than the retention window go away.
#
# Called after every successful deploy (bin/deploy.sh, bin/app-deploy) and by
# the docker-prune.timer daily backstop. Concurrent runs are serialised with a
# lock so the per-app deploy timers cannot stampede each other.
#
# Volumes are NEVER pruned unless --volumes is passed explicitly: an unused
# volume is usually a database whose container is merely stopped, not garbage.

RETENTION_DAYS=${PRUNE_RETENTION_DAYS:-5}
PRUNE_VOLUMES=${PRUNE_VOLUMES:-0}
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) RETENTION_DAYS=${2:?--days requires a value}; shift 2 ;;
    --volumes) PRUNE_VOLUMES=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  echo "--days must be a whole number of days (got: $RETENTION_DAYS)" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker not found; skipping prune" >&2; exit 0; }

until_filter="$((RETENTION_DAYS * 24))h"
log() { [[ $QUIET -eq 1 ]] || echo "$@"; }

# Serialise: a dozen per-app deploy timers can fire in the same minute. If a
# prune already holds the lock there is nothing left for this one to reclaim.
LOCK_FILE=${PRUNE_LOCK_FILE:-/var/lock/multi-deploy-prune.lock}
if command -v flock >/dev/null 2>&1 && exec 9>"$LOCK_FILE" 2>/dev/null; then
  if ! flock -n 9; then
    log "another prune is already running; skipping"
    exit 0
  fi
fi

log "== docker prune (unused, older than ${RETENTION_DAYS}d) =="

# Exited/created containers first — they hold references to images.
docker container prune -f --filter "until=$until_filter" || true

# -a drops images with no container referencing them, not just dangling layers.
# The until filter compares image *creation* time, so a long-lived base image
# that no container uses is fair game; images backing running containers are
# never touched regardless of age.
docker image prune -af --filter "until=$until_filter" || true

# Build cache uses its own filter key (last-used, not created).
docker builder prune -af --filter "unused-for=$until_filter" || true

docker network prune -f --filter "until=$until_filter" || true

if [[ $PRUNE_VOLUMES -eq 1 ]]; then
  # No age filter here: `docker volume prune` supports only label filters, so
  # this removes every volume not attached to a container. Destructive.
  log "-- pruning unused volumes (explicitly requested) --"
  docker volume prune -af || true
fi

if [[ $QUIET -eq 0 ]]; then
  echo "-- docker disk usage after prune --"
  docker system df || true
fi
