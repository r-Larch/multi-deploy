#!/usr/bin/env bash
# Multi-deploy app manager
# Usage:
#   app.sh create            # interactive project setup
#   app.sh enable <name>     # enable & start systemd timer
#   app.sh disable <name>    # disable & stop systemd timer
#   app.sh remove <name>     # disable timer and delete project
#   app.sh deploy <name>     # build & up (force deploy)
#   app.sh start <name>      # compose up -d
#   app.sh stop <name>       # compose down
#   app.sh restart <name>    # compose restart
#   app.sh logs <name> [svc] # compose logs
#   app.sh list              # list apps and status
set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/multi-deploy}
PROJECTS_DIR="$INSTALL_DIR/projects"

bold() { echo -e "\e[1m$*\e[0m"; }
red() { echo -e "\e[31m$*\e[0m"; }

default_read() {
  local prompt="$1"; shift || true
  local default_value="${1:-}"; shift || true
  local var
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " var || true
    echo "${var:-$default_value}"
  else
    read -r -p "$prompt: " var || true
    echo "$var"
  fi
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing dependency: $1"; exit 1; }
}

confirm() {
  local prompt="${1:-Proceed?}"; shift || true
  read -r -p "$prompt [y/N]: " ans || true
  [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

slugify() {
  # Keep lowercase letters, digits and dashes
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

find_compose_file() {
  # Look for common compose filenames in repo root
  local repo_dir="$1"
  local -a candidates=(docker-compose.yml docker-compose.yaml compose.yml compose.yaml)
  local found=()
  for f in "${candidates[@]}"; do
    if [[ -f "$repo_dir/$f" ]]; then found+=("$f"); fi
  done
  if (( ${#found[@]} == 1 )); then
    echo "${found[0]}"; return 0
  elif (( ${#found[@]} > 1 )); then
    echo "Multiple compose files found:" >&2
    local i=1
    for f in "${found[@]}"; do echo "  [$i] $f" >&2; ((i++)); done
    while true; do
      read -r -p "Select compose file number: " idx || true
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#found[@]} )); then
        echo "${found[idx-1]}"; return 0
      fi
      echo "Invalid selection" >&2
    done
  fi
  return 1
}

list_services_from_compose() {
  # Best-effort parse of top-level service keys from a compose file
  local compose_path="$1"
  awk '
    /^[ \t]*services:[ \t]*$/ {in_s=1; base=match($0,/[^ ]/)-1; next}
    in_s==1 {
      # End of services block when indentation goes back to base and next key starts
      if ($0 !~ /^[ \t]*$/ && match($0,/[^ ]/)-1 <= base && $0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*-/) { exit }
      if (match($0,/^([ \t]{2,})([A-Za-z0-9_.-]+):[ \t]*$/, m)) {
        ind=length(m[1]);
        if (!svc_ind) svc_ind=ind;
        if (ind==svc_ind) print m[2];
      }
    }
  ' "$compose_path" | sort -u
}

extract_traefik_labels() {
  # Grep traefik labels present in the compose file (best-effort)
  local compose_path="$1"
  grep -n "traefik\." "$compose_path" || true
}

ensure_dirs() {
  mkdir -p "$PROJECTS_DIR"
}

load_project() {
  local name="$1"
  PROJ_META_DIR="$PROJECTS_DIR/$name"
  PROJ_ENV="$PROJ_META_DIR/project.env"
  PROJ_REPO_DIR="$PROJ_META_DIR/code"
  PROJ_OVERRIDE="$PROJ_META_DIR/compose.server.yml"
  if [[ ! -f "$PROJ_ENV" ]]; then red "Missing $PROJ_ENV"; exit 1; fi
  # shellcheck disable=SC1090
  source "$PROJ_ENV"
  if [[ -z "${COMPOSE_FILE:-}" ]]; then red "COMPOSE_FILE not set in $PROJ_ENV"; exit 1; fi
  PROJ_COMPOSE_BASE="$PROJ_REPO_DIR/$COMPOSE_FILE"
}

resolve_env_file() {
  COMPOSE_ENV_ARG=()
  local ef="${ENV_FILE:-}"
  if [[ -n "$ef" ]]; then
    if [[ -f "$ef" ]]; then
      COMPOSE_ENV_ARG=(--env-file "$ef")
    elif [[ -f "$PROJ_REPO_DIR/$ef" ]]; then
      COMPOSE_ENV_ARG=(--env-file "$PROJ_REPO_DIR/$ef")
    else
      echo "Warning: env file not found: $ef" >&2
    fi
  fi
}

build_compose_cmd() {
  compose_cmd=(docker compose)
  # optional env file
  if (( ${#COMPOSE_ENV_ARG[@]} > 0 )); then
    compose_cmd+=("${COMPOSE_ENV_ARG[@]}")
  fi
  compose_cmd+=(-f "$PROJ_COMPOSE_BASE")
  if [[ -f "$PROJ_OVERRIDE" ]]; then
    compose_cmd+=(-f "$PROJ_OVERRIDE")
  fi
}

ensure_repo() {
  # Clone if repo missing, using existing watch-and-deploy logic
  if [[ ! -d "$PROJ_REPO_DIR/.git" ]]; then
    echo "Cloning repo for project '$NAME' into $PROJ_REPO_DIR ..."
    "$INSTALL_DIR/bin/watch-and-deploy.sh" "$REPO" "$NAME" "$BRANCH" "$COMPOSE_FILE" "${ENV_FILE:-}"
  fi
}

cmd_create() {
  require_bin git
  ensure_dirs

  echo
  bold "New project setup"

  local name repo branch
  name=$(default_read "Project name (slug)" "")
  name=$(slugify "$name")
  if [[ -z "$name" ]]; then red "Project name required"; exit 1; fi

  repo=$(default_read "Git repo URL (SSH)" "git@github.com:org/repo.git")
  if [[ -z "$repo" ]]; then red "Repo URL required"; exit 1; fi

  branch=$(default_read "Git branch" "main")
  if [[ -z "$branch" ]]; then branch=main; fi

  # Paths per layout:
  # - metadata and override in $INSTALL_DIR/projects/<name>
  # - repo worktree in $INSTALL_DIR/projects/<name>/code
  local meta_dir="$PROJECTS_DIR/$name"
  local repo_dir="$PROJECTS_DIR/$name/code"

  # Create meta dir and repo dir
  if [[ -e "$meta_dir" ]]; then
    echo "Directory $meta_dir already exists."
    if ! confirm "Continue and reuse it?"; then exit 1; fi
  fi
  mkdir -p "$meta_dir"

  if [[ -d "$repo_dir/.git" ]]; then
    echo "Repo already present at $repo_dir. Fetching updates..."
    (cd "$repo_dir" && git fetch --all --prune)
  else
    echo "Cloning $repo into $repo_dir ..."
    mkdir -p "$repo_dir"
    git clone "$repo" "$repo_dir"
  fi

  # Robust checkout of branch
  (
    cd "$repo_dir"
    git fetch --all --prune
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git checkout "$branch"
      git pull --ff-only || true
    elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git checkout -B "$branch" --track "origin/$branch"
      git pull --ff-only || true
    else
      red "Branch '$branch' not found on origin. Staying on current branch." || true
    fi
  )

  # Detect compose file in repo root
  local compose_file
  if ! compose_file=$(find_compose_file "$repo_dir"); then
    red "No compose file found in $repo_dir. You can create one and rerun."
    exit 1
  fi
  echo "Using compose file: $compose_file"

  local compose_path="$repo_dir/$compose_file"

  # List services
  echo
  echo "Detecting services in $compose_file ..."
  mapfile -t services < <(list_services_from_compose "$compose_path")
  if (( ${#services[@]} == 0 )); then
    red "No services found in $compose_file"; exit 1
  fi
  echo "Found services: ${services[*]}"

  # Choose the primary service to expose via Traefik
  local svc=""
  echo
  echo "Select the service to expose behind Traefik:"
  local i=1
  for s in "${services[@]}"; do echo "  [$i] $s"; ((i++)); done
  while true; do
    read -r -p "Service number: " idx || true
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#services[@]} )); then
      svc="${services[idx-1]}"; break
    fi
    echo "Invalid selection"
  done

  echo
  echo "Existing Traefik-related labels in $compose_file (if any):"
  extract_traefik_labels "$compose_path" | sed 's/^/  /' || true

  # Ask for Traefik settings
  echo
  local domain router entrypoints certresolver port
  domain=$(default_read "Production domain (Host rule)" "www.example.com")
  router=$(default_read "Router/service name (for labels)" "$svc")
  entrypoints=$(default_read "Traefik entrypoints" "websecure")
  certresolver=$(default_read "Traefik certresolver" "letsencrypt")
  port=$(default_read "Internal app port (container)" "8080")

  # Write project.env into meta dir (matches systemd EnvironmentFile path)
  local env_path="$meta_dir/project.env"
  cat >"$env_path" <<EOF
# Auto-generated by app.sh create
NAME=$name
REPO=$repo
BRANCH=$branch
COMPOSE_FILE=$compose_file
# Optional path to .env file passed to compose (if compose does not use local .env)
ENV_FILE=
EOF

  # Write compose.server.yml override into meta dir (matches watcher path)
  local bt=$'`'
  local override_path="$meta_dir/compose.server.yml"
  cat >"$override_path" <<EOF
services:
  $svc:
    networks:
      - web
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=web"
      - "traefik.http.services.$router.loadbalancer.server.port=$port"
      - "traefik.http.routers.$router.entrypoints=$entrypoints"
      - "traefik.http.routers.$router.tls.certresolver=$certresolver"
      - "traefik.http.routers.$router.rule=Host(${bt}$domain${bt})"

networks:
  web:
    external: true
    name: web
EOF

  echo
  bold "Review"
  echo "Project meta dir:  $meta_dir"
  echo "Repo worktree:     $repo_dir"
  echo "Repo URL:          $repo"
  echo "Branch:            $branch"
  echo "Compose file:      $compose_file"
  echo "Expose service:    $svc"
  echo "Domain:            $domain"
  echo "Router name:       $router"
  echo "Entrypoints:       $entrypoints"
  echo "Certresolver:      $certresolver"
  echo "Internal port:     $port"
  echo "project.env:       $env_path"
  echo "override compose:  $override_path"

  echo
  bold "Next steps"
  echo "- cd $repo_dir"
  echo "- Configure your app if required (env, secrets, migrations, etc.)"
  echo "- Then enable deployments: $(basename "$0") enable $name"

  bold "Done. Project '$name' created."
}

cmd_enable() {
  local name=${1:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") enable <name>"; exit 1; fi
  if [[ ${EUID:-$UID} -ne 0 ]]; then
    sudo systemctl enable --now "multi-deploy@${name}.timer"
  else
    systemctl enable --now "multi-deploy@${name}.timer"
  fi
  echo "Enabled timer for '$name'"
}

cmd_disable() {
  local name=${1:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") disable <name>"; exit 1; fi
  if [[ ${EUID:-$UID} -ne 0 ]]; then
    sudo systemctl disable --now "multi-deploy@${name}.timer"
  else
    systemctl disable --now "multi-deploy@${name}.timer"
  fi
  echo "Disabled timer for '$name'"
}

cmd_remove() {
  local name=${1:-}
  local proj_dir="$PROJECTS_DIR/$name"
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") remove <name>"; exit 1; fi
  if [[ ! -d "$proj_dir" ]]; then red "Project '$name' not found at $proj_dir"; exit 1; fi
  bold "Disabling timer for '$name'..."
  if [[ ${EUID:-$UID} -ne 0 ]]; then
    sudo systemctl disable --now "multi-deploy@${name}.timer"
  else
    systemctl disable --now "multi-deploy@${name}.timer"
  fi
  bold "Removing project directory: $proj_dir"
  rm -rf "$proj_dir"
  # Remove example project if present
  if [[ "$name" == "example" && -d "$PROJECTS_DIR/example" ]]; then
    rm -rf "$PROJECTS_DIR/example"
    echo "Example project removed."
  fi
  echo "Project '$name' removed."
}

cmd_deploy() {
  local name=${1:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") deploy <name>"; exit 1; fi
  load_project "$name"
  resolve_env_file
  ensure_repo
  build_compose_cmd
  echo "Building images..."
  "${compose_cmd[@]}" build --pull
  echo "Applying stack..."
  "${compose_cmd[@]}" up -d --remove-orphans
  echo "Deployed '$name'"
}

cmd_start() {
  local name=${1:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") start <name>"; exit 1; fi
  load_project "$name"
  resolve_env_file
  ensure_repo
  build_compose_cmd
  "${compose_cmd[@]}" up -d
  echo "Started '$name'"
}

cmd_stop() {
  local name=${1:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") stop <name>"; exit 1; fi
  load_project "$name"
  resolve_env_file
  ensure_repo
  build_compose_cmd
  "${compose_cmd[@]}" down
  echo "Stopped '$name'"
}

cmd_restart() {
  local name=${1:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") restart <name>"; exit 1; fi
  load_project "$name"
  resolve_env_file
  ensure_repo
  build_compose_cmd
  # Prefer compose restart for speed
  "${compose_cmd[@]}" restart || { "${compose_cmd[@]}" up -d --force-recreate; }
  echo "Restarted '$name'"
}

cmd_logs() {
  local name=${1:-}
  local svc=${2:-}
  if [[ -z "$name" ]]; then red "Usage: $(basename "$0") logs <name> [service]"; exit 1; fi
  load_project "$name"
  resolve_env_file
  ensure_repo
  build_compose_cmd
  if [[ -n "$svc" ]]; then
    "${compose_cmd[@]}" logs -f --tail=200 "$svc"
  else
    "${compose_cmd[@]}" logs -f --tail=200
  fi
}

cmd_list() {
  ensure_dirs
  printf "%-24s %-12s %-18s\n" "NAME" "AUTO-DEPLOY" "CONTAINERS"
  printf "%-24s %-12s %-18s\n" "------------------------" "------------" "------------------"
  local d name envf auto out lines running total
  for d in "$PROJECTS_DIR"/*; do
    [[ -d "$d" ]] || continue
    envf="$d/project.env"
    [[ -f "$envf" ]] || continue
    name="$(basename "$d")"
    # Auto-deploy (timer) status
    if systemctl --quiet is-enabled "multi-deploy@${name}.timer" 2>/dev/null; then
      auto="enabled"
    else
      auto="disabled"
    fi
    # Container status
    # shellcheck disable=SC1090
    source "$envf" || true
    PROJ_META_DIR="$d"
    PROJ_REPO_DIR="$d/code"
    PROJ_OVERRIDE="$d/compose.server.yml"
    PROJ_COMPOSE_BASE="$PROJ_REPO_DIR/${COMPOSE_FILE:-}"
    resolve_env_file || true
    build_compose_cmd || true
    out=$({ "${compose_cmd[@]}" ps 2>/dev/null || true; } | sed '/^$/d')
    if [[ -z "$out" || ! -f "$PROJ_COMPOSE_BASE" ]]; then
      printf "%-24s %-12s %-18s\n" "$name" "$auto" "stopped"
      continue
    fi
    # Count containers excluding header row
    lines=$(echo "$out" | awk 'NR>1 {print}' | wc -l | tr -d ' ')
    if [[ "$lines" == "0" ]]; then
      printf "%-24s %-12s %-18s\n" "$name" "$auto" "stopped"
      continue
    fi
    running=$(echo "$out" | grep -i "running" | wc -l | tr -d ' ')
    total="$lines"
    printf "%-24s %-12s %-18s\n" "$name" "$auto" "running ${running}/${total}"
  done
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") create            # interactive project setup
  $(basename "$0") enable <name>     # enable & start systemd timer
  $(basename "$0") disable <name>    # disable & stop systemd timer
  $(basename "$0") remove <name>     # disable timer and delete project
  $(basename "$0") deploy <name>     # build & up (force deploy)
  $(basename "$0") start <name>      # compose up -d
  $(basename "$0") stop <name>       # compose down
  $(basename "$0") restart <name>    # compose restart
  $(basename "$0") logs <name> [svc] # compose logs
  $(basename "$0") list              # list apps and status
USAGE
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    create) shift || true; cmd_create "$@" ;;
    enable) shift || true; cmd_enable "$@" ;;
    disable) shift || true; cmd_disable "$@" ;;
    remove) shift || true; cmd_remove "$@" ;;
    deploy) shift || true; cmd_deploy "$@" ;;
    start)  shift || true; cmd_start "$@" ;;
    stop)   shift || true; cmd_stop "$@" ;;
    restart)shift || true; cmd_restart "$@" ;;
    logs)   shift || true; cmd_logs "$@" ;;
    list)   shift || true; cmd_list "$@" ;;
    -h|--help|help|"") usage ;;
    *) red "Unknown command: $cmd"; echo; usage; exit 1 ;;
  esac
}

main "$@"
