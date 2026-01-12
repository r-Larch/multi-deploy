#!/usr/bin/env bash
set -euo pipefail

# watch-and-deploy.sh <repo_ssh_url> <app_name> <branch> <compose_file>
# Clones/updates the repo under ../apps/<app_name>/code and deploys with docker compose.

repo=${1:?repo ssh url required}
name=${2:?app name required}
branch=${3:?branch required}
compose_file=${4:?compose file required}

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_meta_dir="$root_dir/apps/$name"
app_ssh_dir="$app_meta_dir/.ssh"
app_repo_dir="$app_meta_dir/code"

# Logging (keep 7 days)
log_dir="$app_meta_dir/logs"
mkdir -p "$log_dir"
ts=$(date +"%Y-%m-%d_%H-%M-%S")
log_file="$log_dir/$ts.log"
# Redirect all output to both console and log
exec > >(tee -a "$log_file") 2>&1

echo "== multi-deploy start =="
echo "time=$(date -Is) app=$name branch=$branch"

date +%s >/dev/null # ensure date binary present; no-op

mkdir -p "$app_repo_dir"

if [[ ! -d "$app_repo_dir/.git" ]]; then
  echo "Cloning $repo into $app_repo_dir"
  git clone "$repo" "$app_repo_dir"
fi

compose_path="$app_meta_dir/$compose_file"

"$root_dir/bin/deploy.sh" "$app_repo_dir" "$branch" "$compose_path"
status=$?

echo "== multi-deploy end status=$status =="

# Rotate: delete logs older than 7 days
find "$log_dir" -type f -name '*.log' -mtime +7 -print -delete || true

exit "$status"
