# installicious

Menu-driven Bash framework for setting up a fresh Raspberry Pi OS install
for a specific role. Each role pre-selects a sensible bundle of *features*;
features wrap one or more apt packages plus the config to make them useful.

Supported OS releases: Debian / Raspberry Pi OS **Bookworm** and **Trixie**
(Forky / Duke kept forward-compat in code, but not yet validated). Bullseye
and earlier are not supported.

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

## Verifying an install

`installicious --verify` checks every installer that's been touched on
this box and prints **OK** / **FAIL** / **NOT INSTALLED** per item with
a summary block. Read-only — no root required.

```bash
installicious --verify                  # everything with a status file
installicious --verify --all            # everything in the registry
installicious --verify <id> [<id> ...]  # only the named items
installicious --verify --list           # list known IDs + titles, no checks
installicious --verify --verbose        # add per-check details to each row
```

Sample output:

```
[  OK  ] nginx                  — nginx
[ FAIL ] mariadb                — MariaDB database server
           systemctl is-active mariadb: inactive
[ NOT  ] motd-weather           — MOTD weather panel
           state=uninstalled
============================================================
  Verify summary
============================================================
  OK:            12
  FAIL:           1
  NOT INSTALLED:  3
============================================================
```

What it checks per feature: by default, `dpkg-query` for any apt
package the install body put on the box, plus `systemctl is-active`
for the unit named in the manifest's optional `II_SERVICE` field.
Features with richer liveness needs (nginx, apache, lighttpd, caddy,
mariadb/mysql, the WeeWX family) carry hand-written checks too —
`nginx -t`, `mysql -u root -e "SELECT 1"`, weewx service liveness,
tmpfs mount presence, etc. A feature with nothing to check prints
`(no liveness checks declared)`.

Exit codes:
- `0` — zero FAILs (NOT INSTALLED rows are not failures).
- `1` — at least one FAIL.
- `2` — you passed an unknown ID on the command line.

The full design + per-installer contract: [docs/superpowers/specs/2026-05-24-verify-installed-design.md](docs/superpowers/specs/2026-05-24-verify-installed-design.md).

---

## Roles

| ID              | Title              | Notes                                                      |
|---|---|---|
| `custom`        | Custom             | Bypass the role list; pick features individually.          |
| `webserver`     | Web Server         | Pick exactly one of apache / nginx / lighttpd / caddy.     |
| `weewx`         | WeeWx              | Weather-station Pi. Requires `webserver`; defaults include the three weewx-* RAM wrappers, the MOTD bundle, skyfield, and `ram-logging`. |
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

- **pkupd** — `apt update`, then an upgrade, then (optionally)
  `autoremove`. Triggers a reboot only if apt indicates one is required.
  Editable keys:
  - `PKUPD_UPGRADE_MODE` — `dist-upgrade` (default — pulls new packages
    incl. new-ABI kernels; `full-upgrade` is an accepted alias) or
    `upgrade` (in-place only, never pulls a kernel jump unprompted).
  - `PKUPD_SKIP_WINDOW_MIN` — minutes; after a successful upgrade a
    re-run within this window skips the apt steps (default 60, `0`
    disables the skip; a failed upgrade always re-runs).
  - `PKUPD_AUTOREMOVE` — `true` (default) runs `apt-get autoremove
    --purge` after the upgrade; `false` skips it.
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
  `MOTD_WEATHER_ZIP_CODE` (default `05255`) is the label shown next to
  "Weather" in the banner — cosmetic only, separate from the
  AccuWeather location key.
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

All four backends are in the stock Debian / Raspberry Pi OS archive
(Bookworm + Trixie) — a plain `apt install` suffices, no third-party
repo setup. (`weewx` is the exception in this project — see the WeeWx
section below.)

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

### WeeWx

WeeWx-role-only features (hidden in the Custom flow via
`II_RESTRICT_TO_ROLES="weewx"`). The first six are default-on under the
WeeWx role (`database` leads — the sqlite/mysql/mariadb radio runs first,
before `weewx-setup` writes `weewx.conf`); `weewx-onedrive-backup` is
opt-in (default-off — it needs a one-time manual rclone setup). The role
also makes `webserver` required, pulls in `skyfield` (which transitively
installs the `weewx` apt package + `weewx-setup`), and pre-checks
`ram-logging` (log2ram) since a station Pi is a strict win for offloading
`/var/log` writes to RAM.

**WeeWX isn't in the Debian / Raspberry Pi OS archive** (RPi OS doesn't
mirror it) — so the `weewx` package installer
(`packages/package-weewx.sh`) configures weewx.com's own apt repo on
first install via the generic `apt_add_repo` helper in `lib/apt.sh`. The
repo + key are left in place on `--uninstall` (removing a package is
fine; ripping out a repo is more invasive than warranted). weewx is the
only package in the project that needs this today — every webserver
backend, including Caddy, is in the stock archive.

| ID                      | Title                                            | Default | Reboot      |
|---|---|---|---|
| `database`              | Database backend (sqlite/mysql/mariadb radio)    | off*    | never       |
| `weewx-setup`           | WeeWX station setup (non-interactive config)     | off*    | never       |
| `weewx-webroot`         | WeeWX as default web root                        | off*    | never       |
| `weewx-site-ram`        | WeeWX site on tmpfs (with boot loading page)     | off*    | conditional |
| `weewx-database-ram`    | WeeWX database on zram (validated snapshots)     | off*    | conditional |
| `neowx-material`        | NeoWX Material WeeWX skin                        | off*    | never       |
| `weewx-onedrive-backup` | WeeWX database backup to OneDrive                | off     | never       |

*`II_DEFAULT_SELECTED="off"` at the feature level — but the WeeWx role's
`ROLE_FEATURES_DEFAULT` checks the six `*`-marked features on by default
for that role. `weewx-onedrive-backup` carries no `*`: it's a role
**OPTIONAL** (default-off everywhere) because it needs a manual rclone
prerequisite — see its bullet below.
Naming note: `weewx-site-ram` actually uses **tmpfs** (uncompressed RAM —
no benefit from compression on tiny static HTML), `weewx-database-ram`
uses **zram** (compressed RAM block device — meaningful saves on the
SQLite DB). The `-ram` suffix is uniform with `feature-ram-logging` for
symmetry; the underlying mechanism differs by file.

- **database** — sqlite/mysql/mariadb radio. SQLite is the default (no-op
  leaf — `weewx` ships with SQLite already). Picking **MySQL** or
  **MariaDB** triggers a real install:
  - Installs the server (`default-mysql-server` or `mariadb-server`) when
    `DATABASE_HOST=SELF`; skips the server install when `DATABASE_HOST`
    is a remote IP.
  - Provisions `${DATABASE_NAME}` + `${DATABASE_USER}@localhost` with a
    persisted random password (`/etc/installicious/state/database.creds`,
    mode 0600). AUTO sentinels resolve to `weewx`/`weewx`/random. AUTO
    creds + remote `DATABASE_HOST` is a hard error.
  - Installs the role-specific Python bindings
    (`python3-pymysql` under the WeeWx role).
  - Optional InnoDB Pi-tuning: `DATABASE_INNODB_TUNE=on` writes
    `/etc/mysql/conf.d/installicious-pi.cnf` with
    `innodb_flush_log_at_trx_commit=2` and a Pi-RAM-tier-sized
    `innodb_buffer_pool_size`. `off` removes the drop-in on re-run.
  - Writes `/etc/installicious/state/database.state` for downstream
    features. `feature-weewx-setup` reads it and overlays
    `weewx.conf`'s `[DataBindings]/[Databases]/[DatabaseTypes]` to point
    WeeWX at the picked backend.
  - `feature-weewx-database-ram` and `feature-weewx-onedrive-backup`
    self-skip cleanly when `DATABASE_TYPE != sqlite` (they're
    SQLite-only).
  - Uninstall drops the DB + user, removes the server packages and the
    tune drop-in. **Existing data is destroyed** — logged loudly.
- **weewx-setup** — configures WeeWX non-interactively so the apt
  package never has to prompt. Two layers:
  - **Install-critical settings** (the per-Pi-unique bits) live as
    `WEEWX_STATION_*` keys in `config/weewx.config` and surface on the
    in-menu **Edit Configuration** screen: `WEEWX_STATION_LOCATION`,
    `WEEWX_LATITUDE`, `WEEWX_LONGITUDE`, `WEEWX_ALTITUDE` +
    `WEEWX_ALTITUDE_UNITS`, `WEEWX_STATION_TYPE`, `WEEWX_UNITS`,
    `WEEWX_REGISTER_STATION` + `WEEWX_STATION_URL`. After the apt
    install, these are fed to WeeWX's own reconfigure CLI — `weectl
    station reconfigure` on weewx 5, `wee_config --reconfigure` on
    weewx 4 (auto-detected) — so WeeWX parses and rewrites
    `/etc/weewx/weewx.conf` itself.
  - **Everything else** — report skins, RESTful uploaders, logging,
    retention, driver-specific sections — goes in
    [`overrides/weewx.conf`](overrides/weewx.conf), a partial
    `weewx.conf` you edit with a text editor. After the reconfigure
    pass, `resources/weewx-merge-overrides.py` deep-merges that file
    onto `/etc/weewx/weewx.conf` via `configobj` (a WeeWX dependency).
    An empty / all-comments override file is a no-op.

  Runs before `skyfield` (skyfield's `II_DEPS` pulls it in) so the
  extension installs onto a fully-configured WeeWX. Uninstall restores
  `weewx.conf` from the pre-install snapshot.

  - **Optional SQLite seed.** If the database radio picked SQLite (the
    default) and `overrides/weewx.sdb.override` exists, `weewx-setup`
    copies it to `/var/lib/weewx/weewx.sdb` before WeeWX restarts —
    handy when migrating archive history from another Pi. Guarded
    against clobbering real data: the seed only runs when the live
    `.sdb` is missing or under 100 KiB (WeeWX's empty template is
    ~40 KiB; anything larger is treated as real archive data and
    preserved). Skipped silently on MySQL/MariaDB backends. See
    [`overrides/README.md`](overrides/README.md) for the full how-to.
- **weewx-webroot** — repoints the active webserver backend's default
  site at `$WEEWX_WEB_DIR` (default `/var/www/html/weewx`) so visitors
  hit the WeeWX page at `/` instead of the backend's stock welcome page.
  Backend-agnostic; active backend is detected via the status registry
  at install time, and the right config file is patched in place
  (`/etc/nginx/sites-available/default`,
  `/etc/apache2/sites-available/000-default.conf`,
  `/etc/lighttpd/lighttpd.conf`, or `/etc/caddy/Caddyfile`). Uninstall
  restores the pre-install config from snapshot.
- **weewx-site-ram** — mounts `$WEEWX_WEB_DIR` on tmpfs sized by
  `$WEEWX_TMPFS_SIZE` (default 128M) so WeeWX's ~5-minute report
  regeneration stops hammering the SD card. Drops
  `resources/weewx-loading.html` into `/usr/local/share/weewx-ramdisk/`
  as the master copy, and installs a systemd oneshot that copies it
  onto the (volatile) tmpfs on every boot — but only if WeeWX hasn't
  already regenerated a real `index.html`. Editable:
  `WEEWX_WEB_DIR`, `WEEWX_TMPFS_SIZE`. Uninstall removes the unit, the
  share dir, the fstab entry, and unmounts. **Conflicts** with
  `webserver-under-construction` (they fight for
  `${WEEWX_WEB_DIR}/index.html`); installing `weewx-site-ram` while
  `webserver-under-construction` is present auto-uninstalls the latter
  first.
- **weewx-database-ram** — moves `/var/lib/weewx` to a dedicated
  zram-backed ext4 device with validated snapshots:
  - On install, sizes the zram at `1.5x` current DB size (floor 256M,
    rounded to 128M) and picks `zstd` on Pi 4/5, `lz4` on older.
    Set `WEEWX_DB_ZRAM_SIZE` (e.g. `"1024M"`) to pin the size manually
    when you know the DB is about to grow. Default is `"AUTO"` (or
    empty — both trigger the compute path).
  - Boot: walks the rotation (`weewx.sdb`, `.1`, `.2`, …) until one
    passes `PRAGMA quick_check`; refuses to start if none validate
    rather than hand WeeWX a corrupt DB.
  - Hourly + clean-shutdown: `quick_check` the live DB, then
    `sqlite3 .backup` to a `.tmp`, `PRAGMA integrity_check` the result,
    rotate, atomic mv. Discards the backup if either check fails.
  - Drop-in on `weewx.service` ties its lifecycle to the ramdisk
    service so the user can't restart the ramdisk out from under a
    running WeeWX.
  - Editable: `WEEWX_DB_DIR`, `WEEWX_DB_HDD_DIR`, `WEEWX_DB_ROTATIONS`,
    `WEEWX_DB_ZRAM_SIZE` (`"AUTO"` or empty = auto-compute).
- **neowx-material** — installs the [NeoWX Material
  skin](https://github.com/seehase/neowx-material) (seehase's
  actively-maintained fork) and wires up everything its README calls
  out:
  - **Install** — downloads the extension archive (`NEOWX_EXTENSION_URL`,
    defaults to the fork's `master.zip`; pin a release tag for
    reproducible builds) and installs it via WeeWX's own extension CLI
    (`weectl extension install` on weewx 5, `wee_extension --install` on
    weewx 4, auto-detected).
  - **Localization** — merges `lang` / `HTML_ROOT` / `enable` into
    `[StdReport][[neowx-material]]` in `weewx.conf` so the skin renders
    in `NEOWX_LANG` (radio picker — 11 languages) and writes to
    `NEOWX_HTML_ROOT` (defaults to `WEEWX_WEB_DIR`).
  - **Time & Date** — when `NEOWX_LOCALE` is set, writes a
    `/etc/systemd/system/weewx.service.d/neowx-locale.conf` drop-in with
    `Environment="LANG=…"` so WeeWX renders dates/times in that locale
    (the clean, update-surviving equivalent of the README's "edit
    weewx.service" step). Warns — doesn't fail — if the locale isn't
    generated yet (`feature-locale` or `dpkg-reconfigure locales`
    handles that).
  - **Skin config** — deep-merges
    [`overrides/neowx-material-skin.conf`](overrides/neowx-material-skin.conf)
    onto the skin's `skin.conf` via the same `weewx-merge-overrides.py`
    helper (colour scheme, MQTT, forecast, charts, …). Empty override
    file = no-op.

  Editable: `NEOWX_LANG`, `NEOWX_LOCALE`, `NEOWX_HTML_ROOT`. Uninstall
  removes the extension via the WeeWX CLI (which strips the skin dir +
  its `weewx.conf` section), removes the locale drop-in, and restores
  `weewx.conf` from snapshot.
- **weewx-onedrive-backup** — schedules off-site backups of the WeeWX
  SQLite DB to OneDrive via rclone + systemd timers. Default-off and a
  role **OPTIONAL** (not default) because of a one-time manual step:
  rclone's OneDrive remote is configured on a desktop machine and the
  resulting `rclone.conf` copied to the Pi — the headless OAuth flow is
  fragile, so the feature never attempts it. Walkthrough:
  [`scripts/weewx-onedrive-setup.md`](scripts/weewx-onedrive-setup.md).
  - **Install** — checks the rclone config (at `WEEWX_BACKUP_RCLONE_CONF`)
    exists and its OneDrive remote is reachable, **failing fast** with a
    pointer to the setup guide if not. Then creates the OneDrive folder
    tree, writes `/etc/weewx-onedrive-backup.conf` + the runtime script
    `/usr/local/sbin/weewx-onedrive-backup`, and installs three
    service+timer pairs: daily 02:30, weekly Sun 03:30, monthly 1st 04:30
    (±10 min jitter, chained `After=` so they never run concurrently).
  - **Each run** — always backs up a **disk** copy of the DB, never the
    volatile zram device. If `weewx-database-ram` is installed it flushes
    RAM→disk (`weewx-ram-save`) and uses the SD-card mirror; otherwise it
    uses the plain on-disk DB. It then takes a consistent snapshot with
    the SQLite online-backup API (`sqlite3 .backup` — safe even on a
    live DB), verifies the snapshot (`WEEWX_BACKUP_VERIFY` —
    `integrity`/`quick`/`off`), compresses with zstd (level auto-tuned
    per Pi model), uploads to the tier folder, then prunes that folder
    to its newest N files.
  - `II_DEPS="weewx"` — only the `weewx` package is required. The
    zram-vs-disk detection happens per run inside the runtime script, so
    `weewx-database-ram` is **not** a dependency — adding or removing it
    later is picked up automatically with no re-install.
  - Editable: `WEEWX_BACKUP_RCLONE_CONF`, `WEEWX_BACKUP_DB_PATH`
    (`/var/lib/weewx/weewx.sdb` — update this if a future WeeWX-database
    option renames the file), `WEEWX_BACKUP_KEEP_DAILY` (7),
    `WEEWX_BACKUP_KEEP_WEEKLY` (8), `WEEWX_BACKUP_KEEP_MONTHLY` (12) —
    count-based retention per tier. `WEEWX_BACKUP_VERIFY` and the
    OneDrive remote name + folder root are config-file-only knobs in
    `config/weewx-onedrive-backup.config`. Uninstall stops + removes the
    timers, units, runtime script and config, then reverts the apt
    packages — but deliberately leaves `rclone.conf` and any
    already-uploaded backups in OneDrive intact.

Still freestanding under `scripts/` (not yet first-class features):
`weewx-nginx-ssl.sh` (cert issuance is now covered by
`feature-webserver-ssl` — only the WeeWX-specific config glue remains).

---

## Config files

Static defaults live in `config/`:

- `installicious.config` — paths and global toggles.
- `motd.config`, `webserver.config`, `weewx.config`, `locale.config`,
  etc. — per-feature defaults. Editable keys named in each feature's
  `II_EDITABLE_CONFIG` surface in the in-menu **Edit Configuration**
  screen and are persisted to `/etc/installicious/state/menu-config.sh`.

User-editable config overlays live in `overrides/`:

- Distinct from `config/` (framework defaults). These are files **you
  customize** — the long tail of optional tuning that would bloat the
  Edit Configuration screen if surfaced as `II_EDITABLE_CONFIG` keys.
- `overrides/weewx.conf` — a partial `weewx.conf` deep-merged onto
  `/etc/weewx/weewx.conf` by `weewx-setup`. See
  [`overrides/README.md`](overrides/README.md) for the format.

Runtime state lives under `/etc/installicious/`:

- `logs/` — per-run install logs.
- `status/` — per-feature status (Succeeded / Failed / Interrupted / Skipped).
- `state/` — menu overrides, reboot queue, ACME credentials, resume
  transcript, etc.
- `backup/<id>/<timestamp>/` — pre-install snapshots of every file the
  installer touches. `--uninstall` restores from these.
