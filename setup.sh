#!/usr/bin/env bash
# Run this script to setup the server environment
# Requires root privileges
# OS: Ubuntu 22.04+
set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/multi-deploy}
REPO_URL=${REPO_URL:-https://github.com/r-Larch/multi-deploy.git}

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root"; exit 1; fi

# --- Base packages ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git rsync unzip

# --- Docker (install if missing) ---
if ! command -v docker >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Ensure Docker service is running
systemctl enable --now docker || true

# Add invoking user to docker group (if run via sudo)
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  usermod -aG docker "$SUDO_USER" || true
  echo "Added $SUDO_USER to docker group (re-login required)"
fi

# --- Fetch repo (idempotent, update-safe) ---
mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Always clone fresh copy to temp, then sync into INSTALL_DIR while preserving local state
if git clone --depth 1 "$REPO_URL" "$TMP_DIR/repo"; then
  # Preserve user state: apps/, legacy projects/, Traefik env and cert store
  rsync -a \
    --exclude 'apps/' \
    --exclude 'projects/' \
    --exclude 'traefik/.env' \
    --exclude 'traefik/letsencrypt/' \
    "$TMP_DIR/repo/" "$INSTALL_DIR/"
else
  echo "ERROR: Failed to clone $REPO_URL" >&2
  exit 1
fi

# Ensure directories and executable bits
mkdir -p "$INSTALL_DIR/apps"
chmod +x "$INSTALL_DIR"/bin/*.sh || true
chmod 0644 "$INSTALL_DIR"/etc/systemd/*.service "$INSTALL_DIR"/etc/systemd/*.timer || true

# --- Optional: Prepare SSH (for private repos). Not required for public HTTPS clones ---
SSH_KEY_PATH="/root/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_PATH"
  echo "Generated SSH key. Add this public key to GitHub deploy keys if you plan to use SSH URLs:" 
  echo
  cat "$SSH_KEY_PATH.pub"
  echo
  echo "If you use SSH for git, ensure your shell has an active ssh-agent and the key is loaded:"
  echo "  eval \"$(ssh-agent -s)\""
  echo "  ssh-add $SSH_KEY_PATH"
fi

# Preload GitHub host key (useful for SSH)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if ! grep -q "github.com" /root/.ssh/known_hosts 2>/dev/null; then
  ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts || true
fi

# --- Configure Traefik ACME email (preserve existing) ---
mkdir -p "$INSTALL_DIR/traefik"
TRAEFIK_ENV_FILE="$INSTALL_DIR/traefik/.env"
if [[ -f "$TRAEFIK_ENV_FILE" ]]; then
  # Keep existing value, allow override via env var
  if [[ -n "${TRAEFIK_ACME_EMAIL:-}" ]]; then
    sed -i -E "s/^TRAEFIK_ACME_EMAIL=.*/TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL/" "$TRAEFIK_ENV_FILE" || echo "TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL" >> "$TRAEFIK_ENV_FILE"
  fi
else
  # New install: use provided env var or prompt
  if [[ -z "${TRAEFIK_ACME_EMAIL:-}" ]]; then
    read -r -p "Enter email for Let's Encrypt (TRAEFIK_ACME_EMAIL) [admin@example.com]: " TRAEFIK_ACME_EMAIL || true
    TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL:-admin@example.com}
  fi
  cat >"$TRAEFIK_ENV_FILE" <<EOF
TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL
EOF
fi

# --- Start global Traefik (shared network 'web') ---
mkdir -p "$INSTALL_DIR/traefik/letsencrypt"
chmod 700 "$INSTALL_DIR/traefik/letsencrypt"
# Do NOT delete existing acme.json; create if missing
if [[ ! -f "$INSTALL_DIR/traefik/letsencrypt/acme.json" ]]; then
  touch "$INSTALL_DIR/traefik/letsencrypt/acme.json"
  chmod 600 "$INSTALL_DIR/traefik/letsencrypt/acme.json"
fi
cd "$INSTALL_DIR/traefik"
# Ensure shared network exists (idempotent)
if ! docker network inspect web >/dev/null 2>&1; then
  docker network create web >/dev/null
fi
# Warn if ports 80/443 are already in use
check_port() { local p=$1; if ss -ltn | awk '{print $4}' | grep -q ":${p}$"; then echo "Warning: port $p appears in use. Traefik may fail to bind."; fi; }
check_port 80
check_port 443
# Optionally open UFW ports if firewall is active
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  echo "Opened ports 80/443 in UFW firewall."
fi
# Bring up Traefik with env file (safe to rerun)
docker compose --env-file ./.env up -d
# Health check
sleep 2
if ! docker ps | grep -q traefik; then
  echo "ERROR: Traefik container did not start. Check logs: docker logs traefik" >&2
else
  echo "Traefik is running."
fi

# --- Install systemd units ---
cp "$INSTALL_DIR/etc/systemd/multi-deploy@.service" /etc/systemd/system/
cp "$INSTALL_DIR/etc/systemd/multi-deploy@.timer" /etc/systemd/system/
systemctl daemon-reload

# --- Add PATH for convenience ---
echo 'export PATH="/opt/multi-deploy/bin:$PATH"' > /etc/profile.d/multi-deploy-path.sh
chmod 644 /etc/profile.d/multi-deploy-path.sh

# --- Final hints ---
echo "Setup complete. Next steps:"
echo "  1) Re-login or run: source /etc/profile.d/multi-deploy-path.sh"
echo "  2) Create an app:   app create"
echo "  3) Configure it in: $INSTALL_DIR/apps/<name>/code"
echo "  4) Enable deploys:  app enable <name>"
echo "  5) Remove app:      app remove <name>"
# Remove example app if present
if [[ -d "$INSTALL_DIR/apps/example" ]]; then
  rm -rf "$INSTALL_DIR/apps/example"
  echo "Removed example app."
fi
