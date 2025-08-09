#!/usr/bin/env bash
set -euo pipefail

# watch-and-deploy.sh <repo_ssh_url> <app_name> <branch> <compose_file> [env_file]
# Clones/updates the repo under ../apps/<app_name>/code and deploys with docker compose.

repo=${1:?repo ssh url required}
name=${2:?app name required}
branch=${3:?branch required}
compose_file=${4:?compose file required}
env_file=${5:-}

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_meta_dir="$root_dir/apps/$name"
app_dir="$app_meta_dir/code"

mkdir -p "$app_dir"

if [[ ! -d "$app_dir/.git" ]]; then
  echo "Cloning $repo into $app_dir"
  git clone "$repo" "$app_dir"
fi

# Resolve optional env file; try absolute, meta dir, then repo dir
if [[ -n "$env_file" ]]; then
  if [[ -f "$env_file" ]]; then
    export COMPOSE_ENV_FILE="$env_file"
  elif [[ -f "$app_meta_dir/$env_file" ]]; then
    export COMPOSE_ENV_FILE="$app_meta_dir/$env_file"
  elif [[ -f "$app_dir/$env_file" ]]; then
    export COMPOSE_ENV_FILE="$app_dir/$env_file"
  else
    echo "Warning: env file not found: $env_file" >&2
  fi
fi

compose_path="$app_meta_dir/$compose_file"

"$root_dir/bin/deploy.sh" "$app_dir" "$branch" "$compose_path"
