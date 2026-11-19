# Upgrading from v1 (Traefik) to v2 (Caddy)

v1 routed every app through one Traefik container, configured by Docker labels on the app
containers. v2 routes them through one Caddy container (`multi-deploy-caddy`), configured by plain
files: `apps/<name>/site.caddy` per app and, for at most one app, `apps/<name>/global.caddy`. The
proxy has no Docker socket; it reaches each app through a network alias `<name>-<service>` on the
shared `web` network.

The upgrade happens on the server, one step at a time, and Traefik keeps serving until the
cutover:

1. install the v2 files (Caddy is not started yet)
2. migrate each app (`app migrate-proxy`), deploy it, review its `site.caddy`
3. validate the proxy config
4. cut over: Traefik stops, Caddy starts and gets its certificates
5. verify, and roll back if needed
6. clean up Traefik and the old labels

Run every command as root on the server.

## Before you start

- Back up the state Traefik and the apps keep:
  `tar -czf /root/multi-deploy-v1.tar.gz -C /opt/multi-deploy apps traefik`
  (the archive holds `traefik/letsencrypt/acme.json` with the certificate keys: keep it private).
- DNS of every host must point to the server: Caddy requests new certificates from Let's Encrypt
  during the cutover.
- Plan a short window. The apps stay up through steps 1 to 3; step 4 is the downtime (see
  [Downtime](#downtime)).

## 1. Install the v2 files

Run setup.sh with `REPO_REF` set to the v2 branch or tag. Use the setup.sh of that same ref:

```bash
REF=master   # or the v2 branch or tag you install
MD_ACME_EMAIL=you@example.test REPO_REF=$REF \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/r-Larch/multi-deploy/refs/heads/$REF/setup.sh)"
```

setup.sh sees the running Traefik and stops short of the proxy: it installs the files, writes
`caddy/.env` (the ACME email and the network name) and prints

```text
Files are installed, but Caddy was NOT started: it needs ports 80/443 that Traefik holds.
```

`apps/`, `traefik/.env`, `traefik/dashboard_users` and `traefik/letsencrypt/` are left as they
are.

### Deploys before the cutover

The per-minute timers and `app deploy` keep working. A deploy ends with a proxy reload; while
Caddy is not running and Traefik is, the reload is skipped with one line:

```text
Proxy not migrated to Caddy yet: Traefik (traefik) is serving, so the Caddy reload was skipped (see /opt/multi-deploy/docs/UPGRADING.md).
```

`app delete` behaves the same way. With neither Caddy nor Traefik running, the reload fails.

## 2. Migrate each app

For every app, first the dry run:

```bash
app migrate-proxy myapp
```

It reads the app's Traefik labels from the merged compose config and prints the proposed
`site.caddy` and the diff of the compose file it would edit. Nothing is written.

- `INFO` lines say what was dropped on purpose (an http router that only redirects to https:
  Caddy redirects http to https itself) or what to check (a `forwardauth` became `forward_auth`).
- `TODO` lines are what it cannot translate: basic auth, path rules, priorities, unknown
  middlewares, tcp/udp routers, more than one proxied service, a compose file shape it does not
  edit. With any `TODO` it exits 2 and writes nothing. Write that app's `site.caddy` by hand
  (see below) and add the alias to its `compose.server.yml` yourself.

When the dry run is right:

```bash
app migrate-proxy myapp --write
app deploy myapp
```

`--write` backs the edited file up as `<file>.traefik.bak`, writes `site.caddy`, and puts the
proxied service on the `web` network with the alias `<name>-<service>`. **The `traefik.*` labels
stay**, so the redeployed container is still routed by Traefik: there is no downtime while you
migrate, and a rollback finds every app routable again. Under Caddy the labels do nothing; step 6
removes them.

The edited file is `compose.server.yml`, or the app's own `compose.yml` for a static app that holds
the labels. Labels in the app repo (`code/`) are never edited; `compose.server.yml` gets the alias.

Run `app migrate-proxy myapp` again later and it reports the app as migrated.

### Review site.caddy

`apps/<name>/site.caddy` is the app's Caddy config from now on. A typical one:

```caddy
app.example.test, www.app.example.test {
	import security-headers
	import compress
	reverse_proxy myapp-web:8080 {
		import sse
	}
}
```

The shared snippets in `caddy/snippets/shared.caddy`:

| Snippet | Where | What |
|---|---|---|
| `security-headers` | site block | HSTS with preload, same-origin referrer, SAMEORIGIN framing, nosniff |
| `compress` | site block | zstd/gzip for text types, server-sent events left uncompressed |
| `sse` | inside `reverse_proxy { }` | flush every write (server-sent events, streaming) |

multi-deploy refuses a config that breaks its rules, and names the apps:

- `global.caddy` holds only an `on_demand_tls` block, and **only one app may own `on_demand_tls`**.
- **Only one app may have a catch-all site** (`https://`, `:443`, …), and it must be the
  `on_demand_tls` owner.
- An app's own snippets are named `(<name>-…)`.
- No `log` directive in `site.caddy`: the root Caddyfile logs every site, and a site's own `log`
  would turn access logs off for all the others.

## 3. Validate

```bash
app proxy validate
```

runs multi-deploy's rules, then Caddy's own validation. Before the cutover Caddy is not running,
so it validates the files in a throwaway container of the Caddy image.

## 4. Cut over

```bash
app proxy cutover
```

First a preflight, which changes nothing and prints every check:

- Traefik is running (otherwise there is nothing to cut over), Caddy is not
- every app with Traefik router labels has a `site.caddy`
- `app proxy validate` passes
- every upstream of every `site.caddy` resolves on the `web` network, checked from a throwaway
  container on it (an app that does not resolve has not been redeployed: `app deploy <name>`)
- `caddy/.env` has an ACME email

Then it stops Traefik (`docker compose down` in `traefik/`), starts Caddy (`docker compose up -d`
in `caddy/`), checks that only Caddy publishes port 443, and checks every host of every
`site.caddy` from a container on the `web` network, against Caddy's address: the TLS handshake must
succeed against the system trust and the status must not be 5xx (2xx, 3xx and 4xx all show that
Caddy routes the host). Each host gets up to `MD_PROXY_HOST_TIMEOUT` seconds (default 120) for its
certificate. Catch-all, `http://` and wildcard sites are not checked.

A successful cutover ends with

```text
Cutover done: Caddy serves 12 hosts, Traefik is stopped.
```

If any check fails, it rolls back by itself: Caddy stops, Traefik starts, every host is checked
through Traefik again, and the command exits non-zero naming the hosts that failed:

```text
Cutover failed (hosts not served by Caddy) for: app.example.test
Rollback: stopping Caddy, starting Traefik
  ok   app.example.test: status 200 from traefik
Rolled back: Traefik serves again; Caddy is stopped.
```

### Downtime

The apps are down from the moment Traefik stops until Caddy has a certificate for the host: a few
seconds to start Caddy, then the certificate issuance, usually a few seconds per host. Caddy
requests the certificates in parallel; with many hosts expect up to a minute or two. Caddy keeps
its certificates in `caddy/data/`, which survives a rollback, so a later cutover reuses the ones
it already has.

### Let's Encrypt rate limits

Every cutover asks Let's Encrypt for the certificates Caddy does not have yet, and failed
validations count against the limits (5 failures per hostname per hour; 5 certificates for the
same set of hostnames per week). Do not cycle cutover and rollback: after a failed cutover, find
the cause first (`app proxy logs`, DNS of the failing host, the app itself), then cut over once
more.

## 5. Verify, or roll back

```bash
app proxy status   # each app's hosts and their certificate expiry
app proxy logs     # Caddy's log, access log included
```

`app proxy status` replaces the Traefik dashboard.

To go back to Traefik by hand:

```bash
app proxy rollback
```

It stops Caddy, starts Traefik and checks every host through Traefik: a status below 500 that is
not Traefik's own `404 page not found`. The apps still carry their Traefik labels, so Traefik
routes them as before. Fix the cause, then run `app proxy cutover` again.

## 6. Clean up

Once Caddy has served for a while:

```bash
app proxy cleanup-traefik
```

It refuses unless Caddy is running and Traefik is stopped. It removes the Traefik container and
`traefik/letsencrypt/` (Traefik's certificates and ACME account), keeping a tarball of it in
`backups/traefik-letsencrypt-<date>.tar.gz` (mode 600). The files in `traefik/` stay; a later
release removes them, and with them the way back to Traefik.

Then drop the Traefik labels app by app:

```bash
app migrate-proxy myapp --drop-labels
app deploy myapp
```

`--drop-labels` refuses unless Caddy is running and Traefik is stopped. It removes the
`traefik.*` labels (and their comment lines) from the file `--write` edited, keeps the previous
file as `<file>.labels.bak`, and prints the diff. Labels in the app repo (`code/`) are not
touched: remove them there.

## When the preflight fails

| Check | Fix |
|---|---|
| Traefik is not running | nothing to cut over; on a fresh host setup.sh starts Caddy itself |
| app X: Traefik router labels and no site.caddy | `app migrate-proxy X`, or write its `site.caddy` |
| app proxy validate | the printed rule or Caddy error names the app and the line |
| upstream X does not resolve | `app deploy <name>` so the container joins `web` with its alias |
| caddy/.env has no ACME_EMAIL | rerun setup.sh with `MD_ACME_EMAIL` |
