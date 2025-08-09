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
app_repo_dir="$app_meta_dir/code"

mkdir -p "$app_repo_dir"

if [[ ! -d "$app_repo_dir/.git" ]]; then
  echo "Cloning $repo into $app_repo_dir"
  git clone "$repo" "$app_repo_dir"
fi

compose_path="$app_meta_dir/$compose_file"

"$root_dir/bin/deploy.sh" "$app_repo_dir" "$branch" "$compose_path"
