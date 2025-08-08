# Multi Deploy

Host multiple Docker Compose apps on one Ubuntu server with a single Traefik reverse proxy, automatic HTTPS, and hands-free deployments on git pushes (pull-based).

## Why this repo?

- One Traefik instance terminates TLS for all apps
- Each app lives in its own git repo and Compose file
- No webhooks required: systemd timers poll, build, and restart if there are changes
- Simple, readable Bash scripts and systemd units

## Quick start (one-liner installer)

Run on a fresh Ubuntu 22.04+ server as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/r-Larch/multi-deploy/refs/heads/master/setup.sh)"
```

The installer will:

- Install Docker (if missing)
- Download this repository into `/opt/multi-deploy`
- Ask for your Let's Encrypt email for Traefik and start Traefik on ports 80/443
- Install systemd units for auto-deploy timers
- Add `/opt/multi-deploy/bin` to PATH (new shells)

## Create your first app

1. Create the app definition
   - Run: `app.sh create`
   - Answer prompts (name, repo SSH/HTTPS, branch, service and domain)
   - The repo will be cloned into `/opt/multi-deploy/projects/<name>/code`
   - The script generates `/opt/multi-deploy/projects/<name>/compose.server.yml` with Traefik labels and joins the shared `web` network

2. Configure the app repo if needed
   - `cd /opt/multi-deploy/projects/<name>/code`
   - Set env, secrets, run migrations, etc.

3. Enable auto-deploy
   - Run: `app.sh enable <name>`
   - A systemd timer will poll every minute: fetch, build if changed, and `up -d --remove-orphans`

Disable anytime: `app.sh disable <name>`

## How it works

- Traefik runs globally from `/opt/multi-deploy/traefik` on a shared Docker network named `web`
- Each app defines Traefik labels (via the generated override) so Traefik can route traffic by hostnames
- The systemd service `multi-deploy@<name>.service` reads `/opt/multi-deploy/projects/<name>/project.env` and calls `bin/watch-and-deploy.sh`
- The timer `multi-deploy@<name>.timer` runs the service every minute

## Repository layout

- `/opt/multi-deploy/traefik/`        Traefik compose and config (ACME email in `.env`)
- `/opt/multi-deploy/projects/<name>/`
  - `code/`                           App git worktree (your repo)
  - `project.env`                     App definition (repo, branch, compose file, optional env file)
  - `compose.server.yml`              Server override (joins `web`, adds Traefik labels)
- `/opt/multi-deploy/bin/`            Scripts: `app.sh`, `deploy.sh`, `watch-and-deploy.sh`
- `/opt/multi-deploy/etc/systemd/`    Unit and timer templates

## Requirements

- Ubuntu 22.04+
- Open ports 80 and 443

Git access

- Repos can be public (HTTPS or SSH) or private (SSH recommended). Setup generates an SSH key and preloads GitHub host key. Use HTTPS if you prefer for public repos.

## Compose and Traefik tips

- Don’t publish ports on app services; Traefik connects over the shared `web` network
- Ensure your app listens on the internal port you configure (default 8080)
- Update the router Host rule to your domain (e.g., `example.com`)
- Use additional Traefik labels as needed (middlewares, custom routers, etc.)

## Operations

- Check Traefik: `docker ps`, `docker logs traefik`
- Check a timer: `systemctl status multi-deploy@<name>.timer`
- Check a run: `journalctl -u multi-deploy@<name>.service -n 200 -f`
- Manual deploy: `app.sh enable <name>` triggers on the next minute or run service manually

## Uninstall / Cleanup

- Disable timers: `app.sh disable <name>` for each app
- Stop Traefik: `cd /opt/multi-deploy/traefik && docker compose down`
- Remove directory: `rm -rf /opt/multi-deploy` (be careful)

## FAQ

- Can I use HTTPS clone URLs? Yes. For public repos, HTTPS is fine. For private, use SSH keys.
- How often does it deploy? Every minute by default (see timer).
- Can I prune images? Yes, manually run `docker system prune -f` when desired.
