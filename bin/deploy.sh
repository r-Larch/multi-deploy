#!/usr/bin/env bash
set -euo pipefail

# deploy.sh <app_dir> <branch> <compose_file>
# - Fetches the repo in <app_dir>
# - Checks out <branch>
# - Runs docker compose build/up using the app utilities

app_dir=${1:?app directory required}
branch=${2:?branch required}
compose_file=${3:?compose file required}

if [[ ! -d "$app_dir" ]]; then
  echo "App directory not found: $app_dir" >&2
  exit 1
fi
if [[ ! -d "$app_dir/.git" ]]; then
  echo "ERROR: $app_dir is not a git repository" >&2
  exit 2
fi

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_meta_dir=$(dirname "$compose_file")
app_env="$app_meta_dir/app.env"
if [[ ! -f "$app_env" ]]; then
  echo "Missing app.env at $app_env" >&2
  exit 3
fi
# shellcheck disable=SC1090
source "$app_env"
NAME="${NAME:-$(basename "$app_meta_dir")}"

# Ensure SSH known_hosts for GitHub (idempotent)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
  ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true
fi

# Ensure correct branch and fetch latest refs using app-git
"$root_dir/bin/app-git" "$NAME" fetch
# Switch/track target branch if needed
current_branch=$(git -C "$app_dir" rev-parse --abbrev-ref HEAD || echo "")
if [[ "$current_branch" != "$branch" ]]; then
  "$root_dir/bin/app-git" "$NAME" switch "$branch" || true
fi

# Determine if behind (changes pending)
status_line=$("$root_dir/bin/app-git" "$NAME" status)
behind=$(awk -F 'behind=' '{print $2}' <<< "$status_line" | awk '{print $1+0}')

changed=0
if [[ "${behind:-0}" -gt 0 ]]; then
  changed=1
  echo "Changes detected for $branch. Resetting to origin/$branch ..."
  "$root_dir/bin/app-git" "$NAME" reset-hard || true
fi

# Build only when changed; always run up -d --remove-orphans
if [[ $changed -eq 1 ]]; then
  echo "Building images..."
  "$root_dir/bin/app-compose" "$NAME" build --pull
fi

echo "Starting services..."
"$root_dir/bin/app-compose" "$NAME" up -d --remove-orphans

# Optional: clean old images (disabled by default)
# docker image prune -f
