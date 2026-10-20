# Matrix — Continuwuity self-hosted server

One-command deployment of a Matrix homeserver with web clients, group calls,
push notifications, monitoring and optional bridges.

| Service | Purpose |
|---|---|
| **Continuwuity** | Lightweight Rust Matrix homeserver (community continuation of Conduit/conduwuit) |
| **Element Web** | Browser client at `element.<domain>` |
| **Element Call** | Group calls at `call.<domain>` |
| **LiveKit** | WebRTC SFU (`sfu.<domain>`) |
| **lk-jwt-service** | Issues LiveKit JWTs for Matrix users |
| **coTURN** | TURN/STUN for legacy calls and restrictive networks |
| **Caddy** | Reverse proxy and automatic HTTPS (internal router behind an existing proxy in external mode) |
| **ntfy** | UnifiedPush push gateway for mobile notifications |
| **Uptime Kuma** | Status dashboard at `status.<domain>` |
| **mautrix bridges** | Optional Telegram/Discord/WhatsApp/Signal bridges |

## Requirements

- A Linux server with a public IPv4 address and Docker + Compose v2.
- A domain with DNS control.
- `setup.sh` can install missing packages itself: it detects apt (Debian/Ubuntu),
  dnf (Fedora), pacman (Arch) or zypper (openSUSE), shows the command and asks
  for confirmation. Use `./setup.sh --install-deps` to skip the prompt.
  RHEL/CentOS/Rocky/AlmaLinux need Docker's official repository configured
  manually.
- Ports: `80/tcp`, `443/tcp`, `443/udp` (HTTP/3), `3478/tcp+udp`,
  `7881/tcp+udp`, `49160-49200/udp`, `50000-50100/udp`. If another reverse
  proxy already owns `80/443`, the bundled Caddy moves to `127.0.0.1:8080`
  instead (see *Existing reverse proxy* below).
- About 1 GB RAM for the core stack; bridges add ~100–300 MB each.

## Quick start

```bash
git clone https://github.com/DrygTvoi/matrix-continuwuity-deploy.git
cd matrix-continuwuity-deploy
./setup.sh
```

The script checks for Docker, Compose v2, OpenSSL, curl and python3, offers to
install anything missing, detects an existing reverse proxy on ports 80/443,
then asks for the domain, server IP, admin email, registration mode, optional
bridges and optional custom service hostnames. It generates `.env` and
`config/`, pulls images and starts the core stack, and prints the exact DNS
table and the registration token.

Generate configs without starting anything:

```bash
./setup.sh --no-start
```

Non-interactive (useful for CI):

```bash
NON_INTERACTIVE=1 DOMAIN=example.com SERVER_IP=203.0.113.10 \
  ADMIN_EMAIL=admin@example.com ./setup.sh --no-start
```

## Existing reverse proxy

`setup.sh` checks whether ports 80/443 are already taken. When it finds nginx,
Caddy, Traefik, HAProxy, Apache, or a container publishing those ports, it
switches to **external proxy mode** automatically:

- the bundled Caddy stays in the stack but listens on `127.0.0.1:8080`
  (or on the Docker bridge gateway when the existing proxy is a container);
- automatic HTTPS in Caddy is disabled — your proxy keeps the certificates;
- all Matrix routing still lives in `config/Caddyfile`;
- ready-to-use snippets are written to `config/proxy/`: `nginx.conf`,
  `Caddyfile`, `traefik.yml`, `apache.conf`, `haproxy.cfg` and a `README.md`
  that names the detected proxy.

Apply the snippet for your proxy, reload it, and the stack works. The compose
service is still called `caddy`, so all commands in this README keep working.
External mode needs Docker Compose 2.24.4+ (the `!override` compose tag).

Override detection with `PROXY_MODE=auto` (default), `PROXY_MODE=bundled` or
`PROXY_MODE=external`. The resolved mode is stored in `.env`; an `external`
mode persists across re-runs, so pass `PROXY_MODE=auto` to re-detect after
removing the proxy. Detection uses `ss` and, when available, `docker ps`;
setups where the proxy is not on this host (CDN, tunnel, another machine)
cannot be detected automatically — use `PROXY_MODE=external` there, and
optionally set `EXTERNAL_PROXY=nginx` (or `traefik`, `caddy`, ...) to label the
generated snippets.

## Custom hostnames

By default the service hostnames are `element.<domain>`, `call.<domain>`,
`sfu.<domain>`, `turn.<domain>`, `ntfy.<domain>`, `status.<domain>` and
`bridge.<domain>`. To choose your own (for example `web.example1.com` and
`sfu.example2.com`), set the variables below or answer "yes" to the
interactive prompt:

```bash
NON_INTERACTIVE=1 DOMAIN=example.com \
  ELEMENT_HOST=web.example1.com SFU_HOST=sfu.example2.com \
  ADMIN_EMAIL=admin@example.com ./setup.sh --no-start
```

Available variables: `ELEMENT_HOST`, `CALL_HOST`, `SFU_HOST`, `TURN_HOST`,
`NTFY_HOST`, `STATUS_HOST`, `BRIDGE_HOST`. They are stored in `.env` and reused
on later runs while `SERVER_NAME` stays the same. The main `SERVER_NAME`
remains a single Matrix domain; additional domains for the homeserver itself
would be aliases delegating to it, not extra server names.

## DNS records

All records point at the server's public IP. The names below are the defaults;
with custom hostnames use those instead:

| Hostname | Purpose |
|---|---|
| `<domain>` | homeserver API, `.well-known`, federation on 443 |
| `element.<domain>` | Element Web |
| `call.<domain>` | Element Call |
| `sfu.<domain>` | LiveKit + lk-jwt-service |
| `turn.<domain>` | coTURN |
| `ntfy.<domain>` | push gateway |
| `status.<domain>` | Uptime Kuma |
| `bridge.<domain>` | bridge login UI (only when bridges are enabled) |

Caddy obtains certificates automatically once DNS resolves. In external proxy
mode your proxy owns the certificates instead — make sure they cover every
hostname in `config/proxy/`. Federation uses `<domain>:443` (advertised through
`.well-known/matrix/server`); no separate `:8448` listener is needed. If you
use Cloudflare, set these records to **DNS-only** (grey cloud), otherwise the
HTTP-01 challenge cannot reach the server.

## First account

Open `https://element.example.com` and register. With the default token-only
mode, the registration token printed by `setup.sh` is required. **The first
account becomes the server admin** and is invited to the admin room. Accept
that invite before registering bridges.

If you lose admin access, temporarily add an `emergency_password` to
`config/continuwuity.toml`, restart the homeserver, log in, then remove the
line and restart again. Continuwuity warns when this password is left enabled
permanently, because it is a standing backdoor into the server account.

## Calls

Element Web opens Element Call on `call.<domain>`. Element Call uses LiveKit
through `lk-jwt-service`; legacy clients use TURN credentials served by
Continuwuity.

TURN-over-TLS (`turns:` on port 5349) is disabled by default because the proxy
layer owns the certificates. To enable it, issue a certificate for
`turn.<domain>` with your ACME client, mount it into the `coturn` container,
remove `no-tls` from `config/turnserver.conf`, and add the `turns:` URI to
`turn_uris` in `config/continuwuity.toml`.

Firewall test after setup:

```bash
curl "https://<domain>/_matrix/client/r0/voip/turnServer" \
  -H "Authorization: Bearer <access_token>"
```

## Push notifications (Android)

Element Web shows browser notifications while its tab is open. Closed-tab web
push needs a separate Web Push gateway and is not configured here.

ntfy implements the Matrix push gateway and works as a UnifiedPush distributor:

1. Install the **ntfy** app and add `https://ntfy.example.com` as a distributor.
2. In Element Android / Element X, set `https://ntfy.example.com` as the push
   gateway (UnifiedPush).
3. The homeserver sends notifications to `/_matrix/push/v1/notify`; ntfy
   forwards them to the `up*` topic registered by the client.

Anonymous writes are allowed only to `up*` and the `alerts` topic. Everything
else is deny-all. Create a user for your phone if you want to subscribe to
`alerts`:

```bash
docker compose exec ntfy ntfy user add --role=admin admin
docker compose exec ntfy ntfy access admin '*' read-write
```

iOS uses APNs through Element's gateway and is not covered by a self-hosted
ntfy instance.

## Monitoring

- **Uptime Kuma**: `https://status.<domain>` — create the admin account on the
  first visit and add HTTP checks for:
  - `https://<domain>/_matrix/client/versions`
  - `https://<domain>/.well-known/matrix/client`
  - `https://element.<domain>/`
  - `https://call.<domain>/`
  - `https://sfu.<domain>/healthz`
  - `https://ntfy.<domain>/v1/health`
  - TCP `turn.<domain>:3478`
- Configure an **ntfy** notification in Kuma: server `https://ntfy.<domain>`,
  topic `alerts`.
- The `healthcheck` container independently checks the internal services every
  60 seconds and publishes DOWN/UP transitions to the same ntfy topic. Follow
  it with `docker compose logs -f healthcheck`.

## Bridges

Enable bridges interactively in `setup.sh`, or set them manually in `.env`:

```dotenv
BRIDGES=telegram,discord,whatsapp,signal
COMPOSE_PROFILES=telegram,discord,whatsapp,signal
TELEGRAM_API_ID=123456
TELEGRAM_API_HASH=...
```

Then regenerate the bridge configs/registrations and register them after
creating the admin account:

```bash
./setup.sh --force --no-start
docker compose up -d --force-recreate \
  continuwuity caddy livekit lk-jwt element-call element-web coturn ntfy uptime-kuma healthcheck
./scripts/register-bridges.sh
```

`--force-recreate` makes Continuwuity/Caddy/LiveKit pick up the regenerated
config files and secrets. `register-bridges.sh` starts the bridge containers
after they have been registered. To regenerate an **existing** bridge
registration, add `--reset-bridges` and unregister the old appservice first.

The last command logs in as the admin, sends
`!admin appservices register` with each `bridges/<name>/registration.yaml`,
and starts the bridge containers. If you are re-registering an existing
bridge, first remove the old one in the admin room with
`!admin appservices unregister <id>`.

Then open a DM with the bridge bot:

| Bridge | Bot | Login |
|---|---|---|
| Telegram | `@telegrambot:<domain>` | `login` |
| Discord | `@discordbot:<domain>` | `login` |
| WhatsApp | `@whatsappbot:<domain>` | `login` |
| Signal | `@signalbot:<domain>` | `login` |

Telegram requires API credentials from <https://my.telegram.org/apps>.
WhatsApp and Signal require separate phone numbers. Bridges use SQLite in
`bridges/<name>/`.

## Re-running setup

Running `./setup.sh` again on an existing installation is safe:

- existing values from `.env` are used as defaults (domain, server IP, admin
  email, registration mode, bridges, custom hostnames, proxy mode);
- TURN, LiveKit and registration secrets are **reused**, so running clients and
  services keep working;
- generated configs are rewritten, and the core containers (plus bridges that
  are already running) are recreated with `--force-recreate` so the new files
  take effect;
- `data/` is never touched; changing `SERVER_NAME` while the database is
  non-empty is still refused.

Use `--rotate-secrets` to generate new TURN/LiveKit/registration secrets
(for example after a leak), and `--reset-bridges` to regenerate bridge
registrations (re-register them afterwards). If `.env` is missing, setup
recovers the domain and
secrets from the generated configs where possible, but custom hostnames and
other non-secret settings must be supplied again — keep a backup of `.env`.

## Operations

```bash
# logs
docker compose logs -f
docker compose logs -f continuwuity

# update pinned images (tags are updated by Renovate)
./scripts/update.sh

# backup (stops the DB services briefly; optional restic off-site copy)
./scripts/backup.sh

# restore
./scripts/restore.sh latest

# open firewall ports + fail2ban jail for failed logins
sudo ./scripts/harden.sh

# compose status
docker compose ps
```

Image tags are pinned in `docker-compose.yml`. Install the
[Renovate app](https://github.com/apps/renovate) on the repository to get
upgrade PRs; `.github/workflows/ci.yml` validates shell, Python and compose
syntax on every push.

For a busy federated server, Continuwuity recommends a local caching resolver
(Unbound/dnsproxy); Docker's built-in resolver is fine for small deployments.
See <https://continuwuity.org/guides/dns>.

## Security notes

- `.env`, `config/` and `bridges/*/registration.yaml` contain secrets and are
  gitignored. Backups contain them too.
- The homeserver container runs read-only, without capabilities, as your host
  user.
- Caddy adds HSTS, `X-Content-Type-Options` and `Referrer-Policy`; access logs
  are JSON and can be consumed by fail2ban.
- Docker publishes ports through iptables and can bypass ufw/firewalld. Use
  your provider's firewall/security group for strict inbound control. The
  fail2ban jail watches Caddy logs, but its iptables bans may not apply to
  Docker-forwarded traffic.
- In external proxy mode Caddy binds to `127.0.0.1` (or the Docker bridge
  gateway) and is not reachable from the internet directly. Do not set
  `CADDY_INTERNAL_BIND=0.0.0.0`: Docker publishes around ufw/firewalld.
- Token-only registration is the default. Rotate `REGISTRATION_TOKEN` with
  `./setup.sh --force --rotate-secrets` (it recreates the core services), or by
  changing it in `config/continuwuity.toml` and running
  `docker compose restart continuwuity`.
- Disable registration after onboarding users:
  set `allow_registration = false` in `config/continuwuity.toml` and restart.

## Migrating from the old Conduit stack

This repository previously used `matrixconduit/matrix-conduit`. Continuwuity's
RocksDB schema is **not compatible with the original Conduit database**, so
there is no in-place upgrade from that stack. If you have data to keep, migrate
to **Tuwunel** instead (it supports in-place Conduit migration since v1.8.0),
or start fresh on Continuwuity. See
<https://matrix-construct.github.io/tuwunel/>.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Copyright © 2026 DrygTvoi.
