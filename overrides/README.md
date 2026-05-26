# overrides/

User-editable config-overlay files. This folder is **yours to customize** —
distinct from `config/`, which holds installicious's framework defaults.

The split exists so the in-menu **Edit Configuration** screen stays short:
the handful of settings that genuinely differ per-Pi and are needed for an
install to succeed live as `II_EDITABLE_CONFIG` keys (surfaced on that
screen); everything else — the long tail of optional tuning — lives here as
plain config-file overlays you edit with a text editor.

## How it's applied

A feature that supports overrides reads its file from this folder during
install and merges it onto whatever the package's own install produced.
The merge is a **deep merge** — you only list the keys you want to change;
unlisted keys keep their installed defaults.

## `.conf` template vs `.override` — where to put YOUR edits

Each override has two filenames, and the framework prefers the personal one:

| File | Role | In git? | Survives `setup.sh` re-sync? |
|---|---|---|---|
| `weewx.conf` | shipped **template** — commented examples, all inert | yes (tracked) | overwritten by the fresh template each re-sync |
| `weewx.override` | **your** copy — real values | no (`.gitignore` excludes `*.override`) | yes — `setup.sh` excludes `*.override` from the sync |

When `feature-weewx-setup` runs, if `weewx.override` exists it's used and
`weewx.conf` is ignored; otherwise `weewx.conf` is used. Same rule for
`neowx-material-skin.conf` / `neowx-material-skin.override`.

**Put your real edits in the `.override` file**, directly under
`/etc/installicious/overrides/` on the Pi:

```bash
# one-time: seed your personal copy from the template
sudo cp /etc/installicious/overrides/weewx.conf \
        /etc/installicious/overrides/weewx.override
sudo nano /etc/installicious/overrides/weewx.override
```

Editing the bare `weewx.conf` instead works for a single run but is wiped
the next time you re-download + `setup.sh` (it's a tracked template; rsync
restores it). The `.override` file is left untouched by `setup.sh` — same
treatment as `state/menu-config.sh`. Re-run installicious for an edited
override to take effect.

## Current override files

| Personal file | Template | Consumed by | Format |
|---|---|---|---|
| `weewx.override` | `weewx.conf` | `feature-weewx-setup` | partial `weewx.conf` (ConfigObj/INI) — deep-merged onto `/etc/weewx/weewx.conf` after the apt install + `weectl station reconfigure` pass |
| `neowx-material-skin.override` | `neowx-material-skin.conf` | `feature-neowx-material` | partial NeoWX Material `skin.conf` (ConfigObj/INI) — deep-merged onto `/etc/weewx/skins/neowx-material/skin.conf` after the extension install |
| `weewx.sdb.override` | — (binary, no template) | `feature-weewx-setup` | full SQLite archive file — drop-in **replaces** `/var/lib/weewx/weewx.sdb` on first install when the live DB is missing or has zero rows in its `archive` table. Falls back to a 1 MiB size check if `sqlite3` isn't on PATH. Only applied when the database radio picked SQLite |
| `rclone.conf.override` | — (credentials, no template) | `feature-weewx-onedrive-backup` | full `rclone.conf` file (INI) — copied to `WEEWX_BACKUP_RCLONE_CONF` (default `/root/.config/rclone/rclone.conf`) as `root:root` mode `0600` **only when the live file doesn't exist**. Skipped if `/root/.config/rclone/rclone.conf` already exists (rclone refreshes its tokens into the live file; overwriting would force re-auth). Lets users pre-stage their desktop-generated rclone.conf and skip the manual `scp + chown + chmod` dance. |

An empty (or all-comments) override file is a no-op — the feature skips the
merge entirely.

## Seeding an initial WeeWX SQLite database

Skip this section if you're letting WeeWX start from scratch.

If you've already got a WeeWX archive from another Pi (or a backup) and you
want a fresh install to start with that history instead of an empty DB,
copy the source `.sdb` to `overrides/weewx.sdb.override`:

```bash
# from your existing Pi
scp /var/lib/weewx/weewx.sdb you@new-pi:/etc/installicious/overrides/weewx.sdb.override
```

On the next install — only if the `database` choice resolved to SQLite —
`feature-weewx-setup` copies it to `/var/lib/weewx/weewx.sdb` before
restarting WeeWX. The guard asks "is the live DB actually empty?":

1. **File missing** → seed.
2. **`sqlite3` available** → `SELECT COUNT(*) FROM archive`. Zero rows
   = no real data yet, safe to seed. Any rows = live data, preserve.
   This is the semantic check, independent of schema size — important
   because WeeWX 5 on Trixie lays down a schema-only `.sdb` at ~512 KiB
   even with zero rows.
3. **`sqlite3` unavailable** → 1 MiB size fallback. Above 1 MiB the live
   DB is treated as real data and left alone.

To force a re-seed, delete the live `.sdb` and re-run the installer:

```bash
sudo systemctl stop weewx
sudo rm /var/lib/weewx/weewx.sdb
sudo installicious   # or rerun setup.sh
```

The seed file itself is gitignored via `*.override` so it never lands in
a public checkout. No effect when the database radio picked
MariaDB / MySQL — the seed file is silently ignored on that backend.

## Pre-staging an rclone.conf for OneDrive backup

If you'll be enabling the `weewx-onedrive-backup` feature and you've already
generated a working `rclone.conf` on a desktop machine (see
[`scripts/weewx-onedrive-setup.md`](../scripts/weewx-onedrive-setup.md) for
the OAuth flow), you can drop it here as `rclone.conf.override` and
installicious will place it for you — no manual `scp` + `chown` + `chmod`.

```bash
# From your desktop machine:
scp $env:APPDATA\rclone\rclone.conf you@pi:/etc/installicious/overrides/rclone.conf.override
```

When `feature-weewx-onedrive-backup` installs:

1. `apt install rclone zstd sqlite3`
2. **If `overrides/rclone.conf.override` exists AND
   `WEEWX_BACKUP_RCLONE_CONF` (default `/root/.config/rclone/rclone.conf`)
   doesn't**, copies the override to `WEEWX_BACKUP_RCLONE_CONF` with
   owner `root:root` and mode `0600`. Existence check only — never
   overwrites a live file (rclone writes its refreshed access tokens
   back into `rclone.conf`; overwriting would force re-auth).
3. Validates the rclone config, creates the OneDrive folder tree,
   wires up the timers.

To force a re-copy after updating your override (e.g. you rotated your
Azure client_secret):

```bash
sudo rm /root/.config/rclone/rclone.conf
sudo installicious
```

The file is gitignored via `*.override`, but it contains your **OAuth
refresh token and (if you used your own Azure app) client_secret** in
plaintext — treat it as credentials. Don't email it, don't paste it,
and `chmod 600` it everywhere it sits.

## `configuration.override` — set editable-config DEFAULTS from a file

The two files above overlay *application* config (`weewx.conf`, `skin.conf`).
`configuration.override` is different: it overrides **installicious's own
editable-config items** — the `II_EDITABLE_CONFIG` keys you'd otherwise set
on the in-menu **Edit Configuration** screen (`MOTD_NAME`, `WEEWX_LATITUDE`,
`PKUPD_UPGRADE_MODE`, `LOCALE_TIMEZONE`, …).

It's a plain `KEY=VALUE` bash file. Drop one onto a fresh Pi and every
install picks up your preferred values — no clicking through the editor.
That's the point: **repeatability**.

Precedence (last wins):

```
config/*.config            framework defaults
overrides/configuration.override   ← your hand-authored baseline
state/menu-config.sh        ← the in-menu editor's output
```

So `configuration.override` beats the shipped defaults, and an in-menu edit
still beats `configuration.override` (the file is your baseline; the menu
tweaks on top of it for the current run).

**Start from the shipped template** — `configuration.override.example`
lists every editable key, grouped by feature, with its default value and a
one-line note, all commented out:

```bash
sudo cp /etc/installicious/overrides/configuration.override.example \
        /etc/installicious/overrides/configuration.override
sudo nano /etc/installicious/overrides/configuration.override
```

Uncomment and edit only the keys you want; leave the rest commented to keep
the framework default. A minimal hand-written file works just as well:

```bash
# installicious editable-config defaults — KEY=VALUE, sourced as bash.
MOTD_NAME="Dan"
WEEWX_STATION_LOCATION="Manchester Center, VT"
WEEWX_LATITUDE="43.167"
WEEWX_LONGITUDE="-73.032"
PKUPD_UPGRADE_MODE="upgrade"
```

`configuration.override.example` is the one override file kept in git (it
has no real values). Your `configuration.override` is gitignored
(`*.override`) and excluded from `setup.sh`'s sync, so it persists at
`/etc/installicious/overrides/` across re-downloads. Edited values take
effect on the next installicious run — the file is part of each
installer's skip-hash, so a change auto-re-triggers the affected
installers (no manual status reset).
