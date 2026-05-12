# installicious

Menu-driven Bash framework for setting up a fresh Raspberry Pi OS install
for a specific role. Each role pre-selects a sensible bundle of *features*;
features wrap one or more apt packages plus the config to make them useful.

Supported OS releases: Debian / Raspberry Pi OS **Bookworm** and **Trixie**
(Forky / Duke kept forward-compat in code, but not yet validated). Bullseye
and earlier are not supported.

> The **WeeWx** role is a work in progress. Its features (currently the
> `skyfield` extension, with `weewx-nginx` / `weewx-database-ramdisk` /
> `weewx-onedrive-backup` wrappers pending) are intentionally omitted from
> this README until the role is finished.

---

## Quick start

```bash
cd /tmp
wget -qO- https://github.com/BroMarduk/installicious/archive/refs/heads/ai-refactor.tar.gz | tar xz
sudo bash installicious-ai-refactor/setup.sh
```

`setup.sh` copies the tree to `/etc/installicious/`, installs the resume
systemd unit and the `/etc/profile.d/installicious.sh` shell wrapper, then
launches the menu (only if it has a real TTY — non-interactive invocations
just print the next-step pointer).

## Day-to-day use

After the first install, open a fresh shell and use the wrapper:

```bash
installicious                        # menu (re-run / re-configure)
installicious --uninstall <id> [...] # roll a feature back
sudo bash /etc/installicious/installicious.sh   # equivalent, any shell
```

When a feature flips the *reload-shell* flag (e.g. `bash` adding aliases),
the wrapper `exec bash -l`s after the run so the new config takes effect
without a manual relogin. Reboot exits skip the reload — the new login
after the reboot already gets the fresh config.

If a feature requests a reboot, installicious requeues itself via the
`installicious-resume` systemd unit. The resume runs on `tty1` and its
transcript is replayed (or live-tailed) on your next interactive login,
no matter what TTY / SSH session you come back on.

---

## Roles

| ID              | Title              | Notes                                                      |
|---|---|---|
| `custom`        | Custom             | Bypass the role list; pick features individually.          |
| `webserver`     | Web Server         | Pick exactly one of apache / nginx / lighttpd / caddy.     |
| `weewx`         | WeeWx              | **WIP** — see note above.                                  |
| `homeassistant` | Home Assistant     | Stub.                                                      |
| `mediaserver`   | Media Server       | Stub.                                                      |
| `pihole`        | Pi-Hole            | Stub.                                                      |

Stub roles fall through to the custom-features picker today.

---

## Features

Defaults reflect the manifest's `II_DEFAULT_SELECTED`. Reboot column maps
to `II_REQUIRES_REBOOT` (`never`, `conditional` — only if the underlying
change actually requires one).

### General

| ID      | Title                          | Default | Reboot     |
|---|---|---|---|
| `pkupd` | Update & Upgrade Packages      | on      | conditional |
| `bash`  | Bash Customizer                | on      | never       |
| `locale`| Set Localizations (US default) | on      | never       |
| `rconf` | Raspberry Pi Configuration     | off     | conditional |

- **pkupd** — `apt update && apt -y full-upgrade`. Triggers a reboot
  only if apt indicates one is required.
- **bash** — installs a curated `.bashrc` / aliases / prompt. Re-login
  is handled automatically by the `installicious` wrapper.
- **locale** — sets language, timezone, console keyboard, and Wi-Fi
  regulatory country. Editable keys: `LOCALE_LANG`, `LOCALE_TIMEZONE`,
  `LOCALE_KEYBOARD_LAYOUT`, `LOCALE_KEYBOARD_MODEL`, `LOCALE_WIFI_COUNTRY`.
- **rconf** — runs `raspi-config nonint` against a set of preferred
  options (predictable iface names off, SSH on, etc.). Conditional
  reboot if a change requires one.

### MOTD bundle

| ID             | Title                                  | Default | Reboot |
|---|---|---|---|
| `motd`         | Login Message of the Day (MOTD)        | on      | never  |
| `motd-weather` | MOTD weather (hourly current conditions) | off   | never  |
| `motd-updates` | MOTD update count (apt)                | off     | never  |

- **motd** — replaces the default Pi banner with a colored panel
  (IP, uptime, disk, etc.). On installs with a desktop session, the
  `/etc/profile` block is TTY-gated and POSIX-sh-compatible so X11 /
  Wayland desktop logins keep working. The original `/etc/motd` is
  backed up and truncated so it doesn't flash before the new banner.
  Editable: `MOTD_NAME`, `MOTD_IP_URL`, `MOTD_SMALL_SIZE` (column
  threshold below which the small variant is used). The weather row
  auto-swaps to a `vcgencmd get_throttled` status line when the
  `motd-weather` add-on isn't installed — so a station Pi without the
  weather add-on shows under-voltage / thermal-throttle state instead
  of an empty "None" row.
- **motd-weather** — adds a current-conditions block. Requires a free
  API key — set `MOTD_WEATHER_API_KEY` and `MOTD_WEATHER_LOC_CODE` in
  the config editor before installing or the install will fail-stop.
- **motd-updates** — adds an "N updates available" line, refreshed by
  cron. Hidden child of `motd` (auto-pulled when `motd` is selected if
  you tick it in the MOTD optional sub-screen).

### System tuning

| ID                | Title                       | Default | Reboot     |
|---|---|---|---|
| `compressed-swap` | Compressed Swap (zram)      | off     | conditional |
| `ram-logging`     | Logging in RAM (log2ram)    | off     | conditional |

- **compressed-swap** — installs and configures `zram-tools`. Editable:
  `ZRAM_PERCENT_OF_RAM`, `ZRAM_COMPRESSION_ALGO`, `ZRAM_SWAP_PRIORITY`.
- **ram-logging** — installs and configures `log2ram` to redirect
  `/var/log` to a tmpfs, flushing to disk on a schedule. Editable:
  `RAMLOG_PROFILE`, `RAMLOG_SIZE_MB`, `RAMLOG_COMPRESSION_ALGO`.

### Web Server

The `webserver` feature is the entry point. It is `exclusive`-grouped
with its four backends — you pick **exactly one**:

| Backend ID  | Title             | Default | Built-in HTTPS         |
|---|---|---|---|
| `nginx`     | nginx             | on      | via `webserver-ssl`    |
| `apache`    | Apache (apache2)  | off     | via `webserver-ssl`    |
| `lighttpd`  | lighttpd          | off     | via `webserver-ssl`    |
| `caddy`     | Caddy             | off     | built in (auto-ACME)   |

`webserver` editable keys (apply to whichever backend was picked):

- `WEBSERVER_DOC_ROOT` — filesystem root (default `/var/www/html`).
- `WEBSERVER_SERVER_NAME` — canonical FQDN. Auto-filled from
  `hostname -f` if blank. Must resolve to a reachable IP for ACME to
  issue a real cert.
- `WEBSERVER_PORT` — non-443 HTTPS port; ignored by Caddy.

Two add-ons sit in the same selection group as the backend:

| Add-on ID                       | Applies to              | Notes |
|---|---|---|
| `webserver-under-construction`  | all four backends       | Drops one of the `resources/html-index-*.html` templates in as the default `index.html`. Picker (`WEBSERVER_UC_TEMPLATE`) is auto-built from whatever `html-index-*.html` files are in `resources/`; default is `midnight-editor`. Drop a new template file in `resources/` and it shows up as a choice automatically. |
| `webserver-ssl`                 | nginx / apache / lighttpd (**not Caddy** — Caddy ships its own ACME client) | Let's Encrypt cert + redirect/deny policy for `:80`. |

`webserver-ssl` editable keys:

- `WEBSERVER_SSL_EMAIL` — Let's Encrypt registration address.
- `WEBSERVER_SSL_METHOD` — `http` (HTTP-01 via webroot, needs `:80`
  reachable from the public Internet) or `dns-cloudflare` (DNS-01 via
  the Cloudflare API; works behind a CF proxy). Default:
  `dns-cloudflare`.
- `WEBSERVER_SSL_CF_TOKEN` — only used with `dns-cloudflare`. Get a
  token at <https://dash.cloudflare.com/profile/api-tokens> with
  **Zone → DNS → Edit** scope. Stored at
  `/etc/installicious/state/cloudflare.ini` (root, 0600).
- `WEBSERVER_SSL_HTTP_POLICY` — what happens to `:80`:
  - `redirect-all` (default) — redirect every HTTP request to HTTPS.
  - `redirect-name` — redirect only when Host matches the canonical
    domain; LAN-IP HTTP stays plain.
  - `deny-http` — block `:80` except `/.well-known/acme-challenge/`.

For Caddy, the same three policy values live on `CADDY_HTTP_POLICY`
(plus `WEBSERVER_SSL_EMAIL`, reused for Caddy's ACME account — leave
blank for anonymous registration). Caddy plugs the policy into its
own auto-HTTPS pipeline; certbot is never invoked.

A `:443` catch-all served by a self-signed cert
(`/etc/installicious/state/caddy-fallback.crt|key`, CN matches
`WEBSERVER_SERVER_NAME`) gives unmatched-SNI HTTPS connections a
cert warning rather than `ERR_SSL_PROTOCOL_ERROR`.

The exact per-backend × per-policy × per-URL behavior is documented
separately in [docs/webserver-ssl-policy-matrix.md](docs/webserver-ssl-policy-matrix.md).

---

## Config files

Static defaults live in `config/`:

- `installicious.config` — paths and global toggles.
- `motd.config`, `webserver.config`, `locale.config`, etc. — per-feature
  defaults. Editable keys named in each feature's `II_EDITABLE_CONFIG`
  surface in the in-menu **Edit Configuration** screen and are persisted
  to `/etc/installicious/state/menu-config.sh`.

Runtime state lives under `/etc/installicious/`:

- `logs/` — per-run install logs.
- `status/` — per-feature status (Succeeded / Failed / Interrupted / Skipped).
- `state/` — menu overrides, reboot queue, ACME credentials, resume
  transcript, etc.
- `backup/<id>/<timestamp>/` — pre-install snapshots of every file the
  installer touches. `--uninstall` restores from these.
