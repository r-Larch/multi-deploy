#!/usr/bin/env bash
set -euo pipefail

# watch-and-deploy.sh <repo_ssh_url> <project_name> <branch> <compose_file> [env_file]
# Clones/updates the repo under ../projects/<project_name>/code and deploys with docker compose.

repo=${1:?repo ssh url required}
name=${2:?project name required}
branch=${3:?branch required}
compose_file=${4:?compose file required}
env_file=${5:-}

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proj_dir="$root_dir/projects/$name/code"
server_compose="$root_dir/projects/$name/compose.server.yml"

mkdir -p "$proj_dir"

if [[ ! -d "$proj_dir/.git" ]]; then
  echo "Cloning $repo into $proj_dir"
  git clone "$repo" "$proj_dir"
fi

# Resolve optional env file; if relative, make it relative to repo worktree
if [[ -n "$env_file" ]]; then
  if [[ -f "$env_file" ]]; then
    export COMPOSE_ENV_FILE="$env_file"
  elif [[ -f "$proj_dir/$env_file" ]]; then
    export COMPOSE_ENV_FILE="$proj_dir/$env_file"
  else
    echo "Warning: env file not found: $env_file" >&2
  fi
fi

compose_files=("$compose_file")
if [[ -f "$server_compose" ]]; then
  compose_files+=("$server_compose")
fi

"$root_dir/bin/deploy.sh" "$proj_dir" "$branch" "${compose_files[@]}"
