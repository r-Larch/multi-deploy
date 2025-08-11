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
   - Run: `app create`
   - Answer prompts (name, repo SSH/HTTPS, branch)
   - The repo will be cloned into `/opt/multi-deploy/apps/<name>/code`
   - The script generates in `/opt/multi-deploy/apps/<name>/`:
     - `compose.yml` (stack file that includes `code/compose*.yml` and `compose.server.yml`)
     - `compose.server.yml` (minimal: joins `web` and sets `traefik.enable=true` for one service)
     - `app.env` with `COMPOSE_FILE=compose.yml`

2. Configure the app repo if needed
   - `cd /opt/multi-deploy/apps/<name>/code`
   - Set env, secrets, run migrations, etc.

3. Enable auto-deploy
   - Run: `app enable <name>`
   - A systemd timer will poll every minute: fetch, build if changed, and `up -d --remove-orphans` against `/opt/multi-deploy/apps/<name>/compose.yml`

Disable anytime: `app disable <name>`
Remove an app: `app delete <name>`

## CLI reference (app)

- `create`
  - Interactive setup wizard
- `enable <name>`
  - Enable and start the per-app systemd timer
- `disable <name>`
  - Disable and stop the per-app systemd timer
- `delete <name>`
  - Disable timer and delete `/opt/multi-deploy/apps/<name>`
- `timers <name> [on|off]`
  - Get/set the systemd timer state (git-backed apps only)
- `deploy <name>`
  - Force deploy now: `docker compose build --pull` then `up -d --remove-orphans`
- `up <name>`
  - Start services: `docker compose up -d`
- `down <name>`
  - Stop services: `docker compose down`
- `restart <name>`
  - Restart services: `docker compose restart` (falls back to `up -d --force-recreate`)
- `logs <name> [service]`
  - Stream logs with `docker compose logs -f --tail=200`
- `pull <name>`
  - Git fetch + reset to origin/BRANCH-NAME
- `shell <name> <service>`
  - Open a shell inside a running container
- `run <name> ...args`
  - Run raw docker compose subcommands with app context
- `list`
  - List all apps with auto-deploy status and container status (e.g., `running 2/3` or `stopped`)
- `detail <name> [service]`
  - Show app path, type, timer state, list of services, and a summary of `docker compose config`. If `service` is provided, prints only that service’s config.

### Git utility (app-git)

- `app-git <name> status` — prints branch, commit, ahead/behind
- `app-git <name> fetch`
- `app-git <name> pull` — fetch + hard reset to origin/BRANCH-NAME
- `app-git <name> reset-hard` — hard reset to origin/BRANCH-NAME
- `app-git <name> switch BRANCH-NAME` — track and switch to origin/BRANCH-NAME

Examples:

```bash
# Manage auto-deploy
app enable myapp
app disable myapp

# Operate the stack
app update myapp          # git pull and deploy
app deploy myapp
app up myapp
app down myapp
app restart myapp
app detail myapp          # prints summary from `docker compose config`
app logs myapp            # all services
app logs myapp api        # one service

# Git helpers
app pull myapp
app shell myapp api
app run myapp ps

# Overview
app list
```

## How it works

- Traefik runs globally from `/opt/multi-deploy/traefik` on a shared Docker network named `web`
- Each app stack is defined by a single compose file at `/opt/multi-deploy/apps/<name>/compose.yml`
  - This file includes the app repo compose (e.g., `code/compose.yml`) and the local `compose.server.yml`
- The systemd service `multi-deploy@<name>.service` reads `/opt/multi-deploy/apps/<name>/app.env` and calls `bin/watch-and-deploy.sh`
- The timer `multi-deploy@<name>.timer` runs the service every minute

## Repository layout

- `/opt/multi-deploy/traefik/`        Traefik compose and config (ACME email in `.env`)
- `/opt/multi-deploy/apps/<name>/`
  - `code/`                           App git worktree (your repo)
  - `app.env`                         App definition (repo, branch, COMPOSE_FILE, optional env file)
  - `compose.yml`                     Stack file that includes repo compose and server override
  - `compose.server.yml`              Server override (joins `web`, adds `traefik.enable=true`)
- `/opt/multi-deploy/bin/`            Scripts: `app`, `app-compose`, `app-git`, `app-deploy`, `deploy.sh`, `watch-and-deploy.sh`
  - All scripts share helpers via `bin/lib-app` and delegate to `app-*` utilities to avoid duplication.
- `/opt/multi-deploy/etc/systemd/`    Unit and timer templates

## Requirements

- Ubuntu 22.04+
- Open ports 80 and 443

Git access

- Repos can be public (HTTPS or SSH) or private (SSH recommended). Setup generates an SSH key and preloads GitHub host key. Use HTTPS if you prefer for public repos.
- If using SSH, ensure your shell has an active ssh-agent and your key is loaded:
  - `eval "$(ssh-agent -s)"`
  - `ssh-add /root/.ssh/id_ed25519`

## Compose and Traefik tips

- Don’t publish ports on app services; Traefik connects over the shared `web` network
- In `compose.server.yml`, only the service needs `traefik.enable=true` and to join the `web` network
- Put all other Traefik labels in your app repo compose if needed (middlewares, routers, etc.)

## Operations

- Check Traefik: `docker ps`, `docker logs traefik`
- Check a timer: `systemctl status multi-deploy@<name>.timer`
- Check a run: `journalctl -u multi-deploy@<name>.service -n 200 -f`
- Auto-deploy logs: per-app logs in `/opt/multi-deploy/apps/<name>/logs/` (kept 7 days)
- Manual deploy: `app enable <name>` triggers on the next minute or run service manually

## Uninstall / Cleanup

- Disable timers: `app disable <name>` for each app
- Remove apps: `app delete <name>`
- Stop Traefik: `cd /opt/multi-deploy/traefik && docker compose down`
- Remove directory: `rm -rf /opt/multi-deploy` (be careful)

## FAQ

- Can I use HTTPS clone URLs? Yes. For public repos, HTTPS is fine. For private, use SSH keys.
- How often does it deploy? Every minute by default (see timer).
- Can I prune images? Yes, manually run `docker system prune -f` when desired.

## TODO

- Shared helper library for scripts (lib-app) [done]
- app detail: include per-service `docker compose config <service>` and richer git status (ahead/behind) [done]
- app create: allow optional name, static apps without timers [done]
- app create: show id_ed25519.pub for deploy key setup (colorized) [todo]
- Auto-deploy logs with rotation (keep last 7 days, include build logs) [done]
- Rename commands: stop->down, start->up, remove->delete [done]
- Add `timers <name> [on|off]` command as a front-end for enable/disable [done]
- New commands: pull, shell, run [done]

