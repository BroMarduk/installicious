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

## `.conf` vs `.conf.dan` — where to put YOUR edits

Each override has two filenames, and the framework prefers the personal one:

| File | Role | In git? | Survives `setup.sh` re-sync? |
|---|---|---|---|
| `weewx.conf` | shipped **template** — commented examples, all inert | yes (tracked) | overwritten by the fresh template each re-sync |
| `weewx.conf.dan` | **your** copy — real values | no (`.gitignore` excludes `*.dan`) | yes — `setup.sh` excludes `*.dan` from the sync |

When `feature-weewx-setup` runs, if `weewx.conf.dan` exists it's used and
`weewx.conf` is ignored; otherwise `weewx.conf` is used. Same rule for
`neowx-material-skin.conf` / `neowx-material-skin.conf.dan`.

**Put your real edits in the `.dan` file**, directly under
`/etc/installicious/overrides/` on the Pi:

```bash
# one-time: seed your personal copy from the template
sudo cp /etc/installicious/overrides/weewx.conf \
        /etc/installicious/overrides/weewx.conf.dan
sudo nano /etc/installicious/overrides/weewx.conf.dan
```

Editing the bare `weewx.conf` instead works for a single run but is wiped
the next time you re-download + `setup.sh` (it's a tracked template; rsync
restores it). The `.dan` file is left untouched by `setup.sh` — same
treatment as `state/menu-config.sh`. Re-run installicious for an edited
override to take effect.

## Current override files

| Personal file | Template | Consumed by | Format |
|---|---|---|---|
| `weewx.conf.dan` | `weewx.conf` | `feature-weewx-setup` | partial `weewx.conf` (ConfigObj/INI) — deep-merged onto `/etc/weewx/weewx.conf` after the apt install + `weectl station reconfigure` pass |
| `neowx-material-skin.conf.dan` | `neowx-material-skin.conf` | `feature-neowx-material` | partial NeoWX Material `skin.conf` (ConfigObj/INI) — deep-merged onto `/etc/weewx/skins/neowx-material/skin.conf` after the extension install |

An empty (or all-comments) override file is a no-op — the feature skips the
merge entirely.
