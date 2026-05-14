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

Edit these files in your installicious checkout (they sync to
`/etc/installicious/overrides/` via `setup.sh`), then re-run installicious
for the changes to take effect.

## Current override files

| File | Consumed by | Format |
|---|---|---|
| `weewx.conf` | `feature-weewx-setup` | partial `weewx.conf` (ConfigObj/INI) — deep-merged onto `/etc/weewx/weewx.conf` after the apt install + `weectl station reconfigure` pass |

An empty (or all-comments) override file is a no-op — the feature skips the
merge entirely.
