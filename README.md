# Multi Deploy

This is a simple setup to deploy multiple docker compose based app on a Ubuntu server.

## Server Setup

1. Download and install

- Create dir: `/opt/multi-deploy/`
- Download and extract the repo (public): <https://github.com/r-Larch/multi-deploy/archive/refs/heads/master.zip> into `/opt/multi-deploy/`
- Run `sudo /opt/multi-deploy/setup.sh`
- Optionally add `/opt/multi-deploy/bin` to your PATH for convenience

During setup you will be asked for the Traefik Let's Encrypt email (TRAEFIK_ACME_EMAIL). This is stored in `/opt/multi-deploy/traefik/.env` and used by Traefik.

1. Create and configure an app

- Run `/opt/multi-deploy/bin/app.sh create` and follow the prompts
- The repo will be cloned to `/opt/multi-deploy/projects/<name>/code`
- Make any required app-specific configuration inside that directory (env, secrets, migrations, etc.)

1. Enable auto-deploy for the app

- Run `/opt/multi-deploy/bin/app.sh enable <name>` to start the systemd timer for periodic deploys (every minute)
- To stop/disable later: `/opt/multi-deploy/bin/app.sh disable <name>`

## Notes

- One global Traefik reverse proxy handles HTTPS for all apps via labels on app services
- Compose projects must declare correct Traefik labels, entrypoints, router rules, and exposed service ports (the helper creates an override with sane defaults)
- No GitHub webhook needed; a timer fetches and deploys periodically
- Repo is public; SSH key generation in setup is optional if you use HTTPS clones, but the workflow assumes SSH by default
- The runner avoids pruning images/volumes. Use `docker system prune` manually when desired
