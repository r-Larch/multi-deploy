#!/usr/bin/env bash
# Run this script to setup the server environment
# Requires root privileges
# OS: Ubuntu 22.04+
set -euo pipefail

INSTALL_DIR=/opt/multi-deploy
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root"; exit 1; fi

apt-get update -y
apt-get install -y git rsync

# Ensure Docker is installed (assumes already installed per note)
if ! command -v docker >/dev/null; then
  echo "Docker not found. Please install Docker Engine and the compose plugin."; exit 1; fi

# Create install directory
mkdir -p "$INSTALL_DIR"
rsync -a --delete "$SRC_DIR/" "$INSTALL_DIR/"

# Prepare SSH (user should add a deploy key to GitHub)
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
  echo "Generated SSH key. Add this public key to GitHub deploy keys:" 
  echo
  cat /root/.ssh/id_ed25519.pub
  echo
fi

# Preload GitHub host key
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if ! grep -q "github.com" /root/.ssh/known_hosts 2>/dev/null; then
  ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts
fi

# Configure Traefik ACME email
read -r -p "Enter email for Let's Encrypt (TRAEFIK_ACME_EMAIL) [admin@example.com]: " TRAEFIK_ACME_EMAIL || true
TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL:-admin@example.com}
mkdir -p "$INSTALL_DIR/traefik"
cat >"$INSTALL_DIR/traefik/.env" <<EOF
TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL
EOF

# Start global Traefik (shared network 'web')
mkdir -p "$INSTALL_DIR/traefik/letsencrypt"
chmod 700 "$INSTALL_DIR/traefik/letsencrypt"
cd "$INSTALL_DIR/traefik"
docker compose --env-file ./.env up -d

# Install systemd units
cp "$INSTALL_DIR/etc/systemd/multi-deploy@.service" /etc/systemd/system/
cp "$INSTALL_DIR/etc/systemd/multi-deploy@.timer" /etc/systemd/system/
systemctl daemon-reload

# Enable timer for first project (example)
# systemctl enable --now multi-deploy@example.timer

echo "Setup complete. To add more projects:"
echo "  $INSTALL_DIR/bin/app.sh create"
echo "  # Then configure your repo at $INSTALL_DIR/projects/<project>/code if needed"
echo "  $INSTALL_DIR/bin/app.sh enable <project>"
