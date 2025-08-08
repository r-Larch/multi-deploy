#!/usr/bin/env bash
# Interactive helper to add a new project to multi-deploy
# OS: Ubuntu 22.04+
# Deps: git, docker (for runtime), systemd
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
  grep -nE '\btraefik\.' "$compose_path" || true
}

ensure_dirs() {
  mkdir -p "$PROJECTS_DIR"
}

main() {
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

  # Paths per new layout:
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

  # Checkout branch
  (cd "$repo_dir" && git checkout "$branch" && git pull --ff-only || true)

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
  local svc="$1" # optional arg
  if [[ -z "${svc:-}" ]]; then
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
  fi

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
# Auto-generated by new-project.sh
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

  if ! confirm "Enable auto-deploy timer and start now?"; then
    echo "Skipped enabling timer. You can run: systemctl enable --now multi-deploy@${name}.timer"
    exit 0
  fi

  # Enable systemd timer; use sudo if not root
  if [[ ${EUID:-$UID} -ne 0 ]]; then
    sudo systemctl enable --now "multi-deploy@${name}.timer"
  else
    systemctl enable --now "multi-deploy@${name}.timer"
  fi

  echo
  bold "Done. Auto-deploy timer active for project '$name'."
}

main "$@"
