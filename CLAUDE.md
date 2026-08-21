# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Multi-Deploy is a server-side tool (pure Bash) for hosting multiple Docker Compose apps on a single Ubuntu host behind one shared Traefik reverse proxy, with git-poll auto-deployment via systemd timers. There is no build step, no test suite, and no compiled language — the deliverable is the set of shell scripts in `bin/`, the systemd unit templates in `etc/`, and the Traefik config in `traefik/`.

It is installed to `/opt/multi-deploy` on the target server (the `INSTALL_DIR`). This repo *is* that directory's contents. Most logic assumes it runs as root on the server; you cannot meaningfully execute it on this Windows dev machine — edits here are pushed to GitHub and pulled onto the server by `setup.sh`.

## Architecture

The CLI is layered. `bin/app` is the user-facing dispatcher; it delegates to small single-purpose scripts, all of which `source bin/lib-app` for shared state and helpers:

- **`bin/app`** — command router (`create`, `deploy`, `list`, `logs`, `ci-logs`, `timers`, `detail`, etc.). Holds the interactive `create` wizard and read-only display commands.
- **`bin/lib-app`** — shared library. The contract everything depends on: `load_app <name>` sources `apps/<name>/app.env` and sets `NAME`, `APP_META_DIR`, `APP_REPO_DIR`, `APP_SSH_DIR`, `APP_COMPOSE_FILE`, and exports `GIT_SSH_COMMAND` (per-app SSH key with fallback to `/root/.ssh`). `build_compose_cmd` assembles the `compose_cmd` array (`docker compose --project-name <NAME> -f <APP_COMPOSE_FILE>`). At source time it also exports `COMPOSE_PARALLEL_LIMIT` (default `1`) so compose builds/pulls one service at a time — set *before* `load_app`, so `app.env`, the systemd `EnvironmentFile`, or an inline `COMPOSE_PARALLEL_LIMIT=4 app deploy x` can raise it.
- **`bin/app-compose <name> ...args`** — loads context, ensures repo cloned, then `exec docker compose ...args`. The single choke point for every compose invocation.
- **`bin/app-git <name> <action>`** — all git operations (`status`, `fetch`, `pull`, `reset-hard`, `switch`) run inside `APP_REPO_DIR`. `status` emits the parseable line `branch=… commit=… ahead=N behind=N`.
- **`bin/app-deploy <name> <update|deploy>`** — `deploy` = `build --pull` + `up -d --remove-orphans`; `update` delegates to `watch-and-deploy.sh`.
- **`bin/watch-and-deploy.sh`** — the unit of work systemd runs each minute. Clones repo if missing, logs to `apps/<name>/logs/<timestamp>.log` (tee'd, rotated after 7 days), calls `deploy.sh`.
- **`bin/deploy.sh`** — change-detection: only `build --pull` when the repo is *behind* origin (parsed from `app-git status`); always runs `up -d --remove-orphans`.
- **`bin/docker-prune.sh`** — disk reclaim. Age-gated (`--days`, default 5) prune of unreferenced images, exited containers, buildx cache and unused networks; `flock`-serialised so the per-app timers don't stampede. Volumes only with explicit `--volumes`. Runs after every successful deploy (both `deploy.sh` and `app-deploy deploy`), plus a daily `docker-prune.timer` backstop; also exposed as `app prune`.

Key principle: git-status logic lives only in `app-git`, and compose invocation lives only in `app-compose`/`build_compose_cmd`. When changing behavior, edit the single owner rather than duplicating — `app detail` and `deploy.sh` deliberately call back into `app-git`/`app-compose` to avoid drift.

### Per-app layout on the server (`/opt/multi-deploy/apps/<name>/`)

- `app.env` — generated config sourced by every command. Keys: `NAME`, `REPO`, `BRANCH`, `COMPOSE_FILE` (always `compose.yml`), optional `ENV_FILE` (path to a compose `--env-file`, relative to the app dir, e.g. `ENV_FILE=.env`; its variables are used for `${VAR}` substitution across the merged compose config — `COMPOSE_ENV_FILE` is the deprecated alias), optional `COMPOSE_PARALLEL_LIMIT` (overrides the serialised default of 1). **An empty/absent `REPO` means a "static app"** — no git, no timer; many commands branch on `[[ -z "${REPO:-}" ]]`.
- `compose.yml` — generated stack file using compose `include:` to merge the repo's compose file (`code/<file>`) with the server override.
- `compose.server.yml` — server-side override: attaches the chosen service to the external `web` network and adds Traefik labels. This is where domain/router config is hand-edited; the repo's own compose stays untouched.
- `code/` — the cloned app git repo.
- `.ssh/id_ed25519` — per-app deploy key (created on `app create` for SSH repos; the public key is printed to add as a deploy key). Falls back to `/root/.ssh` if absent.
- `logs/` — timestamped deploy logs, 7-day retention.

### Auto-deployment flow

`etc/systemd/multi-deploy@.timer` (every 1 min) → `multi-deploy@<name>.service` (oneshot, `EnvironmentFile=apps/%i/app.env`) → `watch-and-deploy.sh` → `deploy.sh`. Timers are toggled via `app timers <name> on|off`, which runs `systemctl enable/disable --now multi-deploy@<name>.timer`. The unit templates are installed to `/etc/systemd/system/` by `setup.sh`; editing the templates in `etc/` requires re-running setup (or copying + `daemon-reload`) on the server to take effect.

### Traefik

A single global Traefik v3.2 instance (`traefik/docker-compose.yml`) owns ports 80/443 and the Let's Encrypt cert store (`traefik/letsencrypt/acme.json`, mode 600). All apps join the shared external Docker network **`web`** for routing. `exposedByDefault=false`, so each app must opt in with `traefik.enable=true` (set in its `compose.server.yml`). `traefik/.env` (ACME email, dashboard toggle) and `dashboard_users` are user state, **excluded from setup.sh's rsync** so updates never clobber them.

## Common tasks

There are no build/lint/test commands. To sanity-check shell edits, run **ShellCheck** (the scripts have `# shellcheck disable=` directives, so they're meant to pass it):

```bash
shellcheck bin/app bin/lib-app bin/app-compose bin/app-deploy bin/app-git bin/deploy.sh bin/watch-and-deploy.sh
```

Server-side install/update (idempotent; preserves `apps/`, `traefik/.env`, `dashboard_users`, `letsencrypt/`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/r-Larch/multi-deploy/refs/heads/master/setup.sh)"
```

End-to-end manual exercise on a server: `app create <name> <repo>` → edit `apps/<name>/compose.server.yml` → `app deploy <name>` → `app logs <name>` / `app ci-logs <name>` (streams deploy logs, auto-rolls to newest file).

## Conventions when editing

- All scripts use `set -euo pipefail` and resolve `INSTALL_DIR` as `${INSTALL_DIR:-/opt/multi-deploy}`; reference sibling scripts as `"$INSTALL_DIR/bin/<name>"`, never by relative path.
- New `app` subcommands: add a `cmd_<x>` function, a `case` arm in `main()`, and a line in `usage()`.
- Keep the `COMPOSE_FILE=compose.yml` indirection — apps are addressed through the generated stack file, not the repo's compose directly.
- Interactive prompts go through `lib-app` helpers (`default_read`, `confirm`, `slugify`, `bold`, `red`); avoid raw `read`/`echo -e` for consistency.
- This is `master`-branch based (the install URL hard-codes `refs/heads/master`).
