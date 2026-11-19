#!/usr/bin/env bash
# Run this script to setup the server environment
# Requires root privileges
# OS: Ubuntu 22.04+
#
# Settings (environment):
#   INSTALL_DIR      install location (default /opt/multi-deploy)
#   REPO_URL         git repository to install from
#   REPO_REF         branch or tag to install (default master)
#   MD_ACME_EMAIL    Let's Encrypt account email for Caddy (prompted for when missing)
#   MD_WEB_NETWORK   name of the shared proxy network (default: the value in caddy/.env, else web)
#   MD_WEB_SUBNET    subnet for that network when setup creates it (default 172.18.0.0/16)
#   MD_CADDY_IMAGE   Caddy image (default caddy:2.11.9-alpine, see caddy/compose.yml)
#   MD_RESOURCE_LABEL  label (key=value) added to the network setup creates; used by tests
set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/multi-deploy}
REPO_URL=${REPO_URL:-https://github.com/r-Larch/multi-deploy.git}
REPO_REF=${REPO_REF:-master}
MD_WEB_NETWORK=${MD_WEB_NETWORK:-$( (sed -n 's/^MD_WEB_NETWORK=//p' "$INSTALL_DIR/caddy/.env" 2>/dev/null || true) | tail -n1)}
MD_WEB_NETWORK=${MD_WEB_NETWORK:-web}
MD_WEB_SUBNET=${MD_WEB_SUBNET:-172.18.0.0/16}
export MD_WEB_NETWORK

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

install_packages() {
  local missing=() bin
  for bin in git rsync curl ssh-keygen jq; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if (( ${#missing[@]} > 0 )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release git rsync unzip openssh-client jq
  fi

  if ! command -v docker >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # shellcheck disable=SC1091
    . /etc/os-release
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      ${VERSION_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if has_systemd; then
    systemctl enable --now docker || true
  fi

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    usermod -aG docker "$SUDO_USER" || true
    echo "Added $SUDO_USER to docker group (re-login required)"
  fi
}

# Clone REPO_REF to a temp dir, then sync into INSTALL_DIR while preserving local state.
fetch_repo() {
  mkdir -p "$INSTALL_DIR"
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  if ! git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$TMP_DIR/repo"; then
    echo "ERROR: Failed to clone $REPO_URL ($REPO_REF)" >&2
    exit 1
  fi
  rsync -a \
    --exclude '.git/' \
    --exclude 'apps/' \
    --exclude 'caddy/.env' \
    --exclude 'caddy/data/' \
    --exclude 'traefik/.env' \
    --exclude 'traefik/dashboard_users' \
    --exclude 'traefik/letsencrypt/' \
    "$TMP_DIR/repo/" "$INSTALL_DIR/"

  mkdir -p "$INSTALL_DIR/apps"
  if [[ -d "$INSTALL_DIR/bin" ]]; then
    find "$INSTALL_DIR/bin" -type f -exec chmod +x {} +
  fi
  chmod 0644 "$INSTALL_DIR"/etc/systemd/*.service "$INSTALL_DIR"/etc/systemd/*.timer || true
}

# Root key for private repos over SSH; apps may also get their own key on `app create`.
prepare_ssh() {
  local key="/root/.ssh/id_ed25519"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f "$key" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$key"
    echo "Generated SSH key. Add this public key to GitHub deploy keys if you plan to use SSH URLs:"
    echo
    cat "$key.pub"
    echo
  fi
  if ! grep -q "github.com" /root/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts || true
  fi
}

# The installed bin/lib-app: running_traefik and the other shared helpers.
load_lib() {
  # shellcheck source=bin/lib-app
  source "$INSTALL_DIR/bin/lib-app"
}

# Creates the proxy network with the fixed subnet when missing; keeps an existing one.
ensure_web_network() {
  local subnet
  if subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$MD_WEB_NETWORK" 2>/dev/null); then
    echo "Network $MD_WEB_NETWORK exists, keeping it (subnet: ${subnet% })."
    return 0
  fi
  local args=(network create --driver bridge --subnet "$MD_WEB_SUBNET")
  if [[ -n "${MD_RESOURCE_LABEL:-}" ]]; then args+=(--label "$MD_RESOURCE_LABEL"); fi
  docker "${args[@]}" "$MD_WEB_NETWORK" >/dev/null
  echo "Created network $MD_WEB_NETWORK (subnet: $MD_WEB_SUBNET)."
}

set_env_key() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# caddy/.env is the container's env_file (ACME_EMAIL) and compose's interpolation source
# (MD_WEB_NETWORK, MD_CADDY_IMAGE), so a later `docker compose up` in caddy/ sees the same
# values. An existing file is kept; settings given to setup override its values.
write_caddy_env() {
  local env_file="$INSTALL_DIR/caddy/.env" email="${MD_ACME_EMAIL:-}"
  mkdir -p "$INSTALL_DIR/caddy"
  if [[ ! -f "$env_file" && -z "$email" ]]; then
    read -r -p "Enter email for Let's Encrypt (MD_ACME_EMAIL): " email || true
    if [[ -z "$email" ]]; then
      echo "ERROR: an ACME email is required; set MD_ACME_EMAIL or enter one at the prompt." >&2
      exit 1
    fi
  fi
  touch "$env_file"
  chmod 600 "$env_file"
  if [[ -n "$email" ]]; then set_env_key "$env_file" ACME_EMAIL "$email"; fi
  set_env_key "$env_file" MD_WEB_NETWORK "$MD_WEB_NETWORK"
  if [[ -n "${MD_CADDY_IMAGE:-}" ]]; then set_env_key "$env_file" MD_CADDY_IMAGE "$MD_CADDY_IMAGE"; fi
}

open_firewall() {
  local p
  if command -v ss >/dev/null 2>&1; then
    for p in 80 443; do
      if ss -ltn | awk '{print $4}' | grep -q ":${p}$"; then
        echo "Warning: port $p appears in use. Caddy may fail to bind."
      fi
    done
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 443/udp || true
    echo "Opened ports 80/443 in UFW firewall."
  fi
}

start_caddy() {
  mkdir -p "$INSTALL_DIR/caddy/data/caddy-data" "$INSTALL_DIR/caddy/data/caddy-config"
  chmod 700 "$INSTALL_DIR/caddy/data"
  (cd "$INSTALL_DIR/caddy" && docker compose up -d)
  if caddy_running; then
    echo "Caddy is running."
  else
    echo "ERROR: Caddy container did not start. Check logs: docker logs multi-deploy-caddy" >&2
    exit 1
  fi
}

# Returns non-zero when a running Traefik means this host still needs the proxy migration.
setup_proxy() {
  local traefik
  traefik=$(running_traefik)
  write_caddy_env
  if [[ -n "$traefik" ]]; then
    echo
    echo "Traefik is running on this host ($(echo "$traefik" | tr '\n' ' ' | sed 's/ $//'))."
    echo "Files are installed, but Caddy was NOT started: it needs ports 80/443 that Traefik holds."
    echo "Migrate the apps to Caddy as described in $INSTALL_DIR/docs/UPGRADING.md."
    return 1
  fi
  ensure_web_network
  open_firewall
  start_caddy
}

install_systemd_units() {
  if ! has_systemd; then
    echo "systemd not found: skipped installing the multi-deploy timers."
    return 0
  fi
  cp "$INSTALL_DIR/etc/systemd/multi-deploy@.service" /etc/systemd/system/
  cp "$INSTALL_DIR/etc/systemd/multi-deploy@.timer" /etc/systemd/system/
  cp "$INSTALL_DIR/etc/systemd/docker-prune.service" /etc/systemd/system/
  cp "$INSTALL_DIR/etc/systemd/docker-prune.timer" /etc/systemd/system/
  systemctl daemon-reload
  # Daily prune backstop (deploys also prune inline; see bin/docker-prune.sh)
  systemctl enable --now docker-prune.timer || true
}

main() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root"; exit 1; fi

  install_packages
  fetch_repo
  load_lib
  prepare_ssh

  local proxy_ready=true
  setup_proxy || proxy_ready=false

  install_systemd_units

  echo "export PATH=\"$INSTALL_DIR/bin:\$PATH\"" > /etc/profile.d/multi-deploy-path.sh
  chmod 644 /etc/profile.d/multi-deploy-path.sh

  if [[ -d "$INSTALL_DIR/apps/example" ]]; then
    rm -rf "$INSTALL_DIR/apps/example"
    echo "Removed example app."
  fi

  if [[ "$proxy_ready" != true ]]; then
    echo "Setup installed the files; finish the proxy migration (docs/UPGRADING.md) before creating apps."
    return 0
  fi
  echo "Setup complete. Next steps:"
  echo "  1) Re-login or run: source /etc/profile.d/multi-deploy-path.sh"
  echo "  2) Create an app:   app create <name>"
  echo "  3) Configure it in: $INSTALL_DIR/apps/<name>/"
  echo "  4) Manual deploy:   app deploy <name>"
  echo "  5) Enable deploys:  app timers <name> on"
  echo "  x) Remove app:      app remove <name>"
}

if [[ "${MD_SETUP_SOURCE_ONLY:-}" != 1 ]]; then
  main "$@"
fi
