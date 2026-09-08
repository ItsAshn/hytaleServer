# Hytale Server — Dockerized for local hosting on a dynamic IP

A Docker setup for running a dedicated [Hytale](https://hytale.com) server on
your own machine at home — built specifically for the common home-hosting
situation where your ISP gives you a **non-static (dynamic) public IP**.

Two problems of home hosting are solved for you:

1. **Headless operation** — the official server's device-flow authentication
   is automated and persisted, so the container survives restarts without you
   logging in again.
2. **Dynamic IP** — an optional DDNS sidecar keeps a hostname (a free
   `myserver.duckdns.org` subdomain, or your **own domain** such as
   `play.example.com` on Cloudflare) pointed at your current IP, so your
   friends always connect to the same address no matter how often your ISP
   changes it.

## How it works

- The image is based on **Java 25** (the Hytale server targets Java 25 and
  uses **QUIC over UDP 5520** — not TCP).
- At container start the official **`hytale-downloader`** CLI downloads (or
  updates) the server files into the `./data` volume. Nothing server-specific
  is baked into the image, so updates are just a restart.
- Authentication uses Hytale's OAuth device flow **once**; the server then
  stores encrypted tokens (`Server/auth.enc`). Because those tokens are
  encrypted against the machine-id, the container persists a **stable
  machine-id inside the data volume** — without this, every restart would
  force you to log in again.
- For the dynamic IP: players never use your raw IP. They connect to a
  hostname that the bundled DDNS updater keeps current.

## Requirements

- Docker with the Compose plugin
- ~4 GB free RAM (8 GB recommended), ~10 GB disk
- A Hytale account (needed once, for the initial device login)
- For internet play: the ability to forward **UDP 5520** on your router
  (not needed for LAN-only play — see below)

## Quickstart

```bash
git clone <this repo> && cd hytaleServer
cp .env.example .env       # adjust settings (server name, memory, …)
docker compose up -d
```

By default Compose builds the image locally from the `Dockerfile`. A prebuilt
image is also published to the GitHub Container Registry by the
[Docker image workflow](.github/workflows/docker-publish.yml) — to use it,
edit `docker-compose.yml`: comment out `build: .` and set
`image: ghcr.io/itsashn/hytale-server:main`, then
`docker compose pull && docker compose up -d`.

Then watch the first-boot login:

```bash
docker compose logs -f hytale
```

### First-boot authentication (once)

On the very first start, two device logins may appear in the log:

1. **Downloader login** — the `hytale-downloader` prints a URL + code to
   authorize downloading the server files.
2. **Server login** — after the server boots, the container automatically
   runs `/auth login device`, which prints a URL + code. Open it, sign in
   with your Hytale account and confirm. The container then automatically
   runs `/auth persistence Encrypted` so the login is stored.

Everything needed (downloader credentials, `auth.enc`, machine-id) lives in
the `./data` volume, so **every restart after this is fully hands-off**.

### Playing with friends over the internet (dynamic IP)

1. **Port forward** UDP **5520** on your router to the machine running the
   container. (QUIC is UDP-only; forwarding TCP does nothing.)
2. **Pick a hostname provider** (below): a free DuckDNS subdomain, your own
   domain on Cloudflare, No-IP, or any provider with an HTTP update API.
3. **Start the updater sidecar** and give your friends the address
   **`<hostname>:5520`**:
   ```bash
   docker compose --profile ddns up -d
   ```
   Whenever your ISP changes your IP, the sidecar updates the DNS record
   within ~5 minutes (`DDNS_INTERVAL`).

#### Option A — free DuckDNS subdomain

Create a subdomain like `myserver.duckdns.org` at
[DuckDNS](https://www.duckdns.org), copy your token, and set in `.env`:

```
DDNS_PROVIDER=duckdns
DDNS_HOSTNAME=myserver.duckdns.org
DDNS_TOKEN=your-token-here
```

#### Option B — your own domain on Cloudflare

Use e.g. `play.example.com` for a domain whose DNS is hosted on Cloudflare:

1. In the Cloudflare dashboard, note your **zone name** (`example.com`).
2. Create an **API token** at
   <https://dash.cloudflare.com/profile/api-tokens> with the permission
   **Zone → DNS → Edit** for that zone.
3. Set in `.env`:
   ```
   DDNS_PROVIDER=cloudflare
   DDNS_ZONE_NAME=example.com
   DDNS_HOSTNAME=play.example.com      # comma-separate several records
   DDNS_API_TOKEN=your-token-here
   ```
   The sidecar creates the A record if missing and keeps it pointed at your
   current IP. Leave `DDNS_PROXIED=false` — proxying would break the direct
   UDP connection the game needs.

#### Other providers

- **No-IP**: `DDNS_PROVIDER=noip` + `DDNS_HOSTNAME`, `DDNS_USERNAME`,
  `DDNS_PASSWORD`.
- **Any HTTP update API**: `DDNS_PROVIDER=custom` + `DDNS_UPDATE_URL`, with
  `{IP}` as the placeholder for the detected public IP.
- **Manual / static IP**: `DDNS_PROVIDER=manual` just prints your current
  public IP so you can create the A record yourself (useful for other DNS
  hosts, or when your IP doesn't actually change), then exits.

### LAN-only play

If you only play on your local network, skip DDNS and port forwarding
entirely — players connect to the host machine's LAN IP, e.g.
`192.168.1.50:5520`.

## Server console

The container runs an interactive console:

```bash
docker attach hytale-server      # detach with Ctrl+P Ctrl+Q
```

Useful commands: `/stop`, `/auth login device`, `/auth persistence Encrypted`,
`/update download` (the container auto-applies it and restarts).

## Updating the server

`DOWNLOAD_ON_START=true` (default) checks for a new server version on every
container start and installs it automatically:

```bash
docker compose restart hytale
```

Set `PATCHLINE=pre-release` in `.env` to run the preview channel instead.

## Configuration

All settings are environment variables in `.env` (see
[.env.example](.env.example) for the documented list): memory, server name,
MOTD, max players, view radius, game mode, JVM flags, and more.

`Server/config.json` is created from these variables on first boot only —
afterwards edit `data/Server/config.json` directly; it is never overwritten.

## Data layout

Everything lives in `./data` — back up this folder and you have everything:

```
data/
├── Server/                  # HytaleServer.jar, config.json, auth.enc, …
│   ├── config.json          # main server config
│   ├── auth.enc             # encrypted auth tokens (tied to machine-id)
│   ├── universe/            # world saves
│   ├── mods/
│   └── logs/
├── Assets.zip               # game assets
├── .machine-id              # stable id keeping auth.enc valid
└── .tools/                  # hytale-downloader + its cached credentials
```

## Notes & troubleshooting

- **Firewall:** allow inbound UDP 5520 on the host too
  (`sudo ufw allow 5520/udp`).
- **CGNAT:** if your ISP doesn't give you a real public IP (port forwarding
  has no effect), DDNS can't help — use an overlay network instead
  (e.g. Tailscale) or a UDP tunnel service.
- **Connect by hostname, not IP**, once DDNS is set up — TLS hostname
  validation may reject raw-IP connections.
- **RAM:** `MaxViewRadius` is the dominant memory driver; the default here is
  12 (official default 32 is heavy for home connections).
- **Permissions:** files in `./data` are owned by `PUID`/`PGID`
  (default 1000) — set them to your host user in `.env` if needed.
