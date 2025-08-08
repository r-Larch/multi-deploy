# Multi-Project Auto-Deploy Server Blueprint

This blueprint sets up a single server to host multiple Dockerized projects with:

- One global Traefik reverse proxy handling HTTPS for all projects (via labels)
- Per-project folders with `compose.yml`
- Automatic deployments on push (without GitHub webhooks)

Approach:

- Use a simple pull-based loop managed by `systemd` timers to periodically `git fetch` and deploy changes (every 1 minute by default). No webhooks needed.
- Each project is described via a small config file (repo, branch, path, compose file, env file, .env location, etc.).
- When changes are detected, the runner does `docker compose build` and `docker compose up -d --remove-orphans`.

Directories

- `server/traefik/`          Global Traefik config and acme storage
- `server/projects/`         Hosted Projects
  - `<name>/`                Project definition
    - `./code/`              Project repo worktree (cloned here)
    - `./project.env`        Project environment
    - `./compose.server.yml` Server compose file
- `server/bin/`              Management scripts
- `server/etc/systemd/`      Systemd unit and timer templates

Global requirements on server

- Ubuntu 22.04+
- Docker + Docker Compose plugin
- `git`
- Open ports 80 and 443

SSH access to GitHub

- Generate SSH key on server (no passphrase) and add the public key to your GitHub org/user deploy keys with read access.

Usage

1. Copy this `./` tree to your server (e.g., `/opt/multi-deploy`).
2. Create SSH key and known_hosts entries.
3. Configure Traefik (acme email, storage path) and start the global proxy.
4. Add a project definition (e.g., run `./bin/new-project.sh`).
5. Script enables the systemd timer for periodic auto-deploy.

Notes

- Traefik runs as a global container and projects only carry labels.
- Compose projects must declare correct Traefik labels, entrypoints, router rules, and exposed service ports.
- The runner intentionally avoids pruning images/volumes. Use `docker system prune` manually when desired.
