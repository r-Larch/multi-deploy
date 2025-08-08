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

# --- Fetch repo (idempotent) ---
mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Always clone fresh copy to temp, then sync into INSTALL_DIR (safe if script was downloaded standalone)
if git clone --depth 1 "$REPO_URL" "$TMP_DIR/repo"; then
  rsync -a --delete "$TMP_DIR/repo/" "$INSTALL_DIR/"
else
  echo "ERROR: Failed to clone $REPO_URL" >&2
  exit 1
fi

# Ensure directories and executable bits
mkdir -p "$INSTALL_DIR/projects"
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
  echo "  eval \"\$(ssh-agent -s)\""
  echo "  ssh-add $SSH_KEY_PATH"
fi

# Preload GitHub host key (useful for SSH)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if ! grep -q "github.com" /root/.ssh/known_hosts 2>/dev/null; then
  ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts || true
fi

# --- Configure Traefik ACME email ---
read -r -p "Enter email for Let's Encrypt (TRAEFIK_ACME_EMAIL) [admin@example.com]: " TRAEFIK_ACME_EMAIL || true
TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL:-admin@example.com}
mkdir -p "$INSTALL_DIR/traefik"
cat >"$INSTALL_DIR/traefik/.env" <<EOF
TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL
EOF

# --- Start global Traefik (shared network 'web') ---
mkdir -p "$INSTALL_DIR/traefik/letsencrypt"
chmod 700 "$INSTALL_DIR/traefik/letsencrypt"
# Pre-create acme.json with secure permissions
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
# Bring up Traefik with env file
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
echo "  2) Create an app:   app.sh create"
echo "  3) Configure it in: $INSTALL_DIR/projects/<name>/code"
echo "  4) Enable deploys:  app.sh enable <name>"
echo "  5) Remove app:      app.sh remove <name>"
# Remove example project if present
if [[ -d "$INSTALL_DIR/projects/example" ]]; then
  rm -rf "$INSTALL_DIR/projects/example"
  echo "Removed example project."
fi
