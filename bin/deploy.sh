#!/usr/bin/env bash
set -euo pipefail

# deploy.sh <project_dir> <branch> [compose_files...]
# - Clones (or fetches) the repo in <project_dir>
# - Checks out <branch>
# - Runs docker compose build/up using one or more compose files

project_dir=${1:?project directory required}
branch=${2:?branch required}
shift 2

if [[ $# -gt 0 ]]; then
  compose_files=("$@")
else
  compose_files=("compose.yml")
fi

if [[ ! -d "$project_dir" ]]; then
  echo "Project directory not found: $project_dir" >&2
  exit 1
fi

cd "$project_dir"

if [[ ! -d .git ]]; then
  echo "ERROR: $project_dir is not a git repository"
  exit 2
fi

# Ensure SSH known_hosts for GitHub
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
  ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
fi

# Ensure desired branch is checked out
current_branch=$(git rev-parse --abbrev-ref HEAD || echo "")
if [[ "$current_branch" != "$branch" ]]; then
  git fetch --all --prune
  git checkout "$branch"
fi

# Always fetch latest refs and detect changes
git fetch --all --prune
if ! git diff --quiet HEAD..origin/"$branch"; then
  echo "Changes detected for $branch. Pulling..."
  git pull --rebase --autostash origin "$branch"
  changed=1
else
  changed=0
fi

# Build compose command
compose_cmd=(docker compose)
# Optional env-file for variable substitution
if [[ -n "${COMPOSE_ENV_FILE:-}" && -f "$COMPOSE_ENV_FILE" ]]; then
  compose_cmd+=(--env-file "$COMPOSE_ENV_FILE")
fi
for f in "${compose_files[@]}"; do
  compose_cmd+=(-f "$f")
done

if [[ $changed -eq 1 ]]; then
  echo "Building images..."
  "${compose_cmd[@]}" build --pull
fi

echo "Starting services..."
"${compose_cmd[@]}" up -d --remove-orphans

# Optional: clean old images (disabled by default)
# docker image prune -f
