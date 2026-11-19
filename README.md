![Multi-Deploy](banner.jpg)

# Multi Deploy

🚀 **Deploy multiple Docker Compose apps effortlessly on a single Ubuntu server**

Perfect for rapid prototyping, staging environments, and cost-effective hosting without complex CI/CD infrastructure. While designed for experiments and staging, it can be used for production but it's not recommended.

## Why Multi Deploy?

**💡 The Problem:** Setting up individual hosting, CI/CD pipelines, and SSL certificates for every experiment or staging app is expensive and time-consuming. Why reinvent the wheel every time?

**✅ The Solution:** One server, one setup, unlimited apps with automatic HTTPS and deployments.

### Key Benefits

- **🏗️ Quick Experiments** — Deploy any Docker Compose app in under 5 minutes
- **💰 Cost Effective** — Host multiple apps on one server instead of paying for separate hosting/serverless
- **🔒 Automatic HTTPS** — Let's Encrypt certificates managed automatically by Caddy
- **🔄 Auto-Deploy** — Git-based deployments without webhooks or complex CI/CD
- **🛠️ Simple Management** — Powerful CLI for app lifecycle and debugging
- **📦 No Vendor Lock-in** — Standard Docker Compose, runs anywhere

### Perfect For

- **Staging environments** for multiple projects
- **Personal projects** and side experiments  
- **Small team demos** and proof-of-concepts
- **Development previews** from feature branches
- **Simple production apps** (where scaling is not needed)

### How It Works

- **One Caddy instance** is the reverse proxy for all apps and gets their certificates
- **Each app** lives in its own Git repo with a standard Docker Compose file
- **Each app's proxy config** is a small file on the server, `apps/<name>/site.caddy`
- **Systemd timers** poll for changes and auto-deploy (no webhooks needed)
- **Simple CLI** manages everything: create, deploy, debug, monitor

## 🚀 Quick Start

### 1. One-Line Setup

Run on a fresh Ubuntu 22.04+ server as root, or to update an existing installation:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/r-Larch/multi-deploy/refs/heads/master/setup.sh)"
```

The installer will:

- Install Docker (if missing)
- Download this repository into `/opt/multi-deploy`
- Create the shared Docker network `web` (subnet `172.18.0.0/16`) if it is missing; an existing one is kept
- Ask for your Let's Encrypt email and start the Caddy proxy (`caddy/`) on ports 80/443
- Install systemd units for auto-deploy timers (skipped where systemd is absent)
- Add `/opt/multi-deploy/bin` to PATH (new shells)

**Upgrading a v1 server (Traefik)?** On a host where a Traefik container runs, the installer
updates the files but does not start Caddy. Follow [docs/UPGRADING.md](docs/UPGRADING.md): it
migrates the apps one by one while Traefik keeps serving, then cuts over in one step, with an
automatic rollback.

Settings, passed as environment variables to the installer:

| Variable | Default | Meaning |
|---|---|---|
| `MD_ACME_EMAIL` | prompt | Let's Encrypt account email, stored in `caddy/.env` |
| `MD_WEB_SUBNET` | `172.18.0.0/16` | subnet of `web` when the installer creates it |
| `MD_WEB_NETWORK` | `web` | name of the shared proxy network (stored in `caddy/.env`) |
| `MD_CADDY_IMAGE` | `caddy:2.11.9-alpine` | Caddy image, e.g. a build with a DNS module (stored in `caddy/.env`) |
| `REPO_REF` | `master` | branch or tag to install |

```bash
MD_ACME_EMAIL=you@example.com REPO_REF=master bash -c "$(curl -fsSL https://raw.githubusercontent.com/r-Larch/multi-deploy/refs/heads/master/setup.sh)"
```

### 2. Create Your First App

```bash
# Interactively create a new app from any Docker Compose repo (private SSH repos supported)
sudo app create myapp git@github.com:user/my-compose-repo.git
# With an SSH repo it shows a deploy key: add it to your repo's settings
```

The wizard asks for the branch, the service to put behind the proxy, its host name(s) and port,
whether it streams responses (server-sent events) and whether to add the shared security headers.
It writes `apps/myapp/site.caddy`:

```caddy
myapp.example.com {
	import security-headers
	reverse_proxy myapp-web:8080
}
```

and `apps/myapp/compose.server.yml`, which puts the service on the `web` network as `myapp-web`,
the name `site.caddy` proxies to. Your repo's compose file stays untouched.

```bash
# Deploy: builds, starts the stack and reloads the proxy
sudo app deploy myapp
# Your app is now live at https://myapp.example.com

# (Optional) Enable auto-deployment (polls every minute for changes)
sudo app timers myapp on

# Manual deployment (pull latest changes and deploy):
sudo app update myapp
```

**What happens behind the scenes:**

- Repo cloned to `/opt/multi-deploy/apps/myapp/code`
- Generated `compose.yml` uses `include:` to merge your repo's compose file with `compose.server.yml`
- Caddy reads `site.caddy` on the reload, gets the host's certificate and proxies to `myapp-web:8080`
- Systemd timer starts polling for git changes and auto-deploying

### 3. That's It

Your app automatically deploys on git pushes. No webhooks, no CI/CD setup required.

## The Proxy

One Caddy container (`multi-deploy-caddy`, from `caddy/compose.yml`) owns ports 80/443 and the
certificates. It reads `caddy/Caddyfile`, which imports:

- `caddy/snippets/*.caddy` — shared snippets, usable by every app:

  | Snippet | Where | What |
  |---|---|---|
  | `security-headers` | site block | HSTS with preload, same-origin referrer, SAMEORIGIN framing, nosniff |
  | `compress` | site block | zstd/gzip for text types; server-sent events stay uncompressed |
  | `sse` | inside `reverse_proxy { }` | flush every write (server-sent events, streaming) |

- `apps/<name>/site.caddy` — the app's site blocks. Edit it by hand to change hosts, add
  redirects, headers and so on, then apply with `app proxy reload`.
- `apps/<name>/global.caddy` — optional, only an `on_demand_tls` block, for the one app that owns
  on-demand TLS.

Caddy has no Docker socket. It reaches each app through a network alias on the shared `web`
network: `compose.server.yml` gives the proxied service the alias `<name>-<service>`, and
`site.caddy` proxies to `<name>-<service>:<port>`.

multi-deploy checks its own rules before Caddy's (`app proxy validate`), and every refusal names
the apps involved:

- `global.caddy` holds only `on_demand_tls`, and at most one app has one
- at most one app has a catch-all site (`https://`, `:443`, …), and it is the `on_demand_tls` owner
- an app's own snippets are named `(<name>-…)`
- no `log` directive in `site.caddy`: the root Caddyfile logs every request of every site to stdout

The root Caddyfile sets no server timeouts: Caddy's defaults have no read or write limit, which
long git pushes and large uploads through the proxy need.

```bash
sudo app proxy validate   # the rules above, then Caddy's own validation
sudo app proxy reload     # validate, then reload without a restart; a refused config keeps the running one
sudo app proxy status     # each app's hosts and their certificate expiry
sudo app proxy logs       # Caddy's log, access log included
```

## App Management

The `app` command provides everything you need to manage your deployments:

### Essential Commands

```bash
# List all apps and their status
sudo app list

# Get detailed info about an app (site.caddy, services, git status)
sudo app detail myapp

# View logs (last 200 lines, follows)
sudo app logs myapp

# Manual deployment (useful for testing)
sudo app deploy myapp

# Start/stop/restart services
sudo app up myapp
sudo app down myapp  
sudo app restart myapp

# Access running containers
sudo app shell myapp [service-name]    # Interactive shell
sudo app run myapp [service-name] command  # Run one-off commands

# Git operations (useful for branch deployments)
sudo app pull myapp                    # Pull latest changes
sudo app git myapp status             # Check git status  
sudo app git myapp switch feature-branch  # Deploy a different branch
```

### Timer Management

```bash
# View auto-deploy status for an app
sudo app timers myapp

# Control auto-deployment
sudo app timers myapp on   # Start auto-deployment timer
sudo app timers myapp off  # Stop auto-deployment (app keeps running)

# Complete removal
sudo app delete myapp    # Disables the timer, stops the containers (named volumes stay), removes the files, drops the routes
```

## 🔧 Troubleshooting

Having issues? The `app` command has built-in debugging tools to help you identify problems quickly.

### Check Overall Health

```bash
# See all apps and their current status
sudo app list

# Get detailed information about a specific app
sudo app detail myapp
# Shows: git status, site.caddy, services, compose config
```

### Debug Deployment Issues

```bash
# Check if auto-deployment is working
sudo app timers myapp

# Manually trigger deployment to see errors
sudo app deploy myapp

# Stream the deploy logs of the timer
sudo app ci-logs myapp

# Check git status for your app
sudo app git myapp status
# Verify repo is clean and on the right branch

# Switch to a different branch if needed
sudo app git myapp switch main
```

### Debug Runtime Issues

```bash
# Check if containers are running
sudo app list

# View real-time logs
sudo app logs myapp
# Add service name for specific container: sudo app logs myapp web

# Check the merged compose config:
sudo app detail myapp

# Access container for debugging
sudo app shell myapp web

# Or run specific commands:
sudo app run myapp ls   # same as: docker compose -f <app-compose-file> ls
sudo app run myapp kill # same as: docker compose -f <app-compose-file> kill

# Restart if containers are stuck
sudo app restart myapp
```

### Common Issues

**App not accessible from web:**

- Check `apps/myapp/site.caddy`: host names, and the upstream `myapp-<service>:<port>`
- `sudo app proxy validate`, then `sudo app proxy reload`
- `sudo app proxy status` shows whether the host has a certificate yet
- `sudo app proxy logs` shows certificate errors and every request
- Verify domain DNS points to your server

**Deployment not happening automatically:**

- Run `sudo app timers` to verify timer is enabled
- Check timer logs: `journalctl -u multi-deploy@myapp.timer`
- Verify git repo is accessible and has changes

**Container won't start:**

- Check logs: `sudo app logs myapp`  
- Try manual deployment: `sudo app deploy myapp`
- Access container for debugging: `sudo app shell myapp service-name`

**Permission issues:**

- All `app` commands should be run with `sudo`
- Check file ownership in `/opt/multi-deploy/apps/myapp/`

## Architecture Overview

### Directory Structure

```text
/opt/multi-deploy/
├── bin/           # CLI tools (app, app-compose, app-git, app-deploy, app-proxy, …)
├── apps/          # Your deployed applications
│   └── myapp/
│       ├── code/               # Your git repo
│       ├── compose.yml         # Generated stack: includes code/<compose file> + compose.server.yml
│       ├── compose.server.yml  # Server override: the proxied service on `web` as myapp-<service>
│       ├── site.caddy          # The app's proxy config
│       ├── global.caddy        # Optional: on_demand_tls (one app at most)
│       ├── logs/               # Deploy logs, 7 days
│       └── app.env             # App settings (repo, branch, …)
├── caddy/         # The Caddy proxy: compose.yml, Caddyfile, snippets/, .env, data/ (certificates)
└── etc/systemd/   # Systemd timer templates
```

A server upgraded from v1 also has `traefik/` until a later release removes it (see
[docs/UPGRADING.md](docs/UPGRADING.md)).

### How Auto-Deployment Works

1. **Systemd timer** (every minute) runs `watch-and-deploy.sh`
2. **Git check:** Fetch latest commits from origin
3. **Change detection:** Compare local vs remote branch  
4. **Build & deploy:** If changes found, run `docker compose build --pull && up -d`, then reload the proxy
5. **Logging:** All output saved to `/opt/multi-deploy/apps/<name>/logs/<timestamp>.log` (kept 7 days)

### Networking

- **External network `web`:** shared by Caddy and the proxied service of every app
- **Network aliases:** each proxied service is `<name>-<service>` on `web`, so two apps may both have a service called `web`
- **Caddy:** TLS termination, routing and Let's Encrypt certificates; no Docker socket
- **Per-app networks:** Each app gets isolated internal networking via Docker Compose

## Advanced Usage

### Custom Compose Files

Your app repo can contain:

- `compose.yml` or `docker-compose.yml` - Main application definition
- Multi-deploy will include both files when building the final stack

### Environment Variables

Set app-specific variables in `/opt/multi-deploy/apps/<name>/app.env`:

```bash
# Edit app environment
sudo nano /opt/multi-deploy/apps/myapp/app.env

# Restart to apply changes
sudo app restart myapp
```

### Build Concurrency

Compose builds/pulls are serialised (`COMPOSE_PARALLEL_LIMIT=1`) so that parallel
BuildKit builds — across services and across apps whose 1-minute timers happen to
fire together — can't starve the host of CPU/RAM. To let a specific app build more
than one service at a time, set it in that app's `app.env`:

```bash
COMPOSE_PARALLEL_LIMIT=4
```

### Keeping Helper Images

Unused images older than 5 days are pruned after every deploy and daily. An image
that only an exited one-shot container uses — a build sandbox image an app starts
with `docker run --rm`, for example — counts as unused and would be deleted. Label
it `multi-deploy.keep=true` and the prune leaves it alone:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:9.0
LABEL multi-deploy.keep=true
```

or at build time: `docker build --label multi-deploy.keep=true -t cms-build:local .`.
The label protects the image only; the build cache is still pruned by age.

### Branch Deployments

Deploy different branches for staging/testing:

```bash
# Switch to feature branch
sudo app git myapp switch feature-xyz

# Deploy the branch
sudo app deploy myapp

# Switch back to main when done
sudo app git myapp switch main
```

### Manual Deployments

Disable auto-deployment for manual control:

```bash
# Stop auto-deployment but keep app running
sudo app timers myapp off

# Deploy manually when ready
sudo app deploy myapp
```

## 📚 Complete CLI Reference

### Main Commands

- **`create`** - Interactive setup wizard for new apps (writes `site.caddy` and `compose.server.yml`)
- **`list`** - List all apps with status (running containers, auto-deploy state)
- **`detail <name> [service]`** - Detailed app info: git status, `site.caddy`, services
- **`delete <name>`** - Remove app completely: disables the timer, runs `docker compose down` (named volumes stay), deletes the files, reloads the proxy
- **`timers <name>`** - Show auto-deploy status for an app
- **`timers <name> on`** - Start auto-deployment timer (polls every minute)
- **`timers <name> off`** - Stop auto-deployment timer (app keeps running)
- **`prune [--days N] [--volumes]`** - Reclaim unused Docker data (images labelled `multi-deploy.keep=true` stay)

### Proxy Commands

- **`proxy validate`** - Check every app's `site.caddy`/`global.caddy` (multi-deploy's cross-app rules, then Caddy's own validation; in a throwaway container while Caddy is not running)
- **`proxy reload`** - Validate, then reload Caddy without a restart; a refused config keeps the running one
- **`proxy status`** - Hosts per app with their certificate expiry
- **`proxy logs [docker-logs-args]`** - Caddy's logs (default: follow, last 200 lines)
- **`proxy cutover`**, **`proxy rollback`**, **`proxy cleanup-traefik`** - Move a v1 server from Traefik to Caddy, see [docs/UPGRADING.md](docs/UPGRADING.md)
- **`migrate-proxy <name> [--write|--drop-labels]`** - Translate an app's Traefik labels (read from the merged compose config) into `site.caddy`. Without `--write` it prints the proposed `site.caddy` and the diff of the compose file it would edit; `--write` backs that file up as `<file>.traefik.bak`, aliases the service on the proxy network as `<name>-<service>` and writes `site.caddy`, keeping the `traefik.*` labels so Traefik routes the app until the cutover (then run `app deploy <name>`). The edited file is `compose.server.yml`, or a static app's own `compose.yml` when that holds the labels; labels in the repo (`code/`) are left there and `compose.server.yml` gets the alias. Anything it cannot translate (basic auth, path rules, priorities, unknown middlewares, tcp/udp routers, more than one proxied service, an unknown file shape) is listed as `TODO` and it exits 2 without writing. `--drop-labels`, after the cutover, removes the `traefik.*` labels (backup `<file>.labels.bak`)

### Deployment Commands

- **`deploy <name>`** - Manual deployment: build, restart containers, reload the proxy
- **`up <name>`** - Start all services with `docker compose up -d`
- **`down <name>`** - Stop all services with `docker compose down`
- **`restart <name>`** - Restart all services

### Debugging Commands

- **`logs <name> [service]`** - View logs (follows by default, last 200 lines)
- **`ci-logs <name>`** - Stream the deploy logs (rolls over to the newest file)
- **`shell <name> <service>`** - Open interactive shell in running container
- **`run <name> <service> command`** - Run one-off command in service container

### Git Commands

All git operations maintain app context and work within the app's code directory:

- **`pull <name>`** - Git fetch + hard reset to origin/branch
- **`git <name> status`** - Show git status (branch, commits ahead/behind)
- **`git <name> fetch`** - Fetch latest commits
- **`git <name> pull`** - Fetch + hard reset to origin/branch  
- **`git <name> reset-hard`** - Hard reset to origin/branch
- **`git <name> switch <branch>`** - Switch and track origin/branch

### Usage Examples

```bash
# Quick health check
sudo app list
sudo app detail myapp

# Manage deployments
sudo app timers myapp on      # Start auto-deployment
sudo app deploy myapp          # Manual deployment
sudo app timers myapp off     # Stop auto-deployment

# Debug issues
sudo app logs myapp web        # View specific service logs
sudo app shell myapp web       # Access container shell
sudo app git myapp status      # Check git state

# Branch deployments
sudo app git myapp switch staging  # Deploy staging branch
sudo app deploy myapp              # Deploy the new branch
sudo app git myapp switch main     # Back to main branch
```

## Requirements & Compatibility

- **OS:** Ubuntu 22.04+ (other Debian-based distros may work)
- **Memory:** 2GB+ recommended (depends on your apps)
- **Storage:** 20GB+ for system + your app containers and logs
- **Network:** Public IP with ports 80/443 accessible
- **Domain:** DNS pointing to your server for automatic HTTPS

### Git Access

- **Public repos:** HTTPS or SSH both work fine
- **Private repos:** SSH recommended (setup generates SSH key automatically)
- **SSH setup:** Ensure your shell has ssh-agent and key loaded if needed:

  ```bash
  eval "$(ssh-agent -s)"
  ssh-add /root/.ssh/id_ed25519
  ```

### Docker Compose Tips

- Don't publish ports on app services; Caddy connects over the shared `web` network
- Only the proxied service joins `web`, with its alias, in `compose.server.yml`; the others stay on the app's own network
- Routing, headers and redirects belong in `site.caddy`, not in Docker labels

## Development

Tests need Docker; everything runs in pinned containers (Git Bash on Windows works):

- `./tests/run.sh` — shellcheck, unit tests, Caddyfile validation
- `./tests/e2e/run.sh` — fresh install with sample apps served over TLS (Caddy's local CA), and a
  v1 install (the `1.1.0` tag) with Traefik upgraded, cut over, rolled back and cleaned up

Test resources carry the label `multi-deploy.test` and use their own network; they are removed at
the end.

## Contributing & Support

This project is designed for simplicity and experimentation. Contributions welcome!

- **Issues:** Report bugs or request features via GitHub Issues
- **Pull Requests:** Improvements to scripts, documentation, or examples
- **Community:** Share your multi-deploy setups and use cases

Remember: This tool prioritizes simplicity over complexity. It's perfect for experiments and staging, but evaluate carefully for production workloads requiring high availability or complex orchestration.
