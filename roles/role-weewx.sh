#!/bin/bash

# WeeWx role - personal weather station software.
#
# REQUIRED installs the apt baseline plus the webserver parent feature,
# which triggers the apache/nginx/lighttpd/caddy radio sub-menu (nginx
# pre-selected). DEFAULT is listed RAM-stuff-first so the user's eye
# lands on the heavy weewx-specific decisions before the general ones,
# and so toggling them up-front communicates what extra packages will
# be pulled (zram-tools, sqlite3, etc.):
#   - the four weewx-specific wrappers:
#       weewx-setup            — configures weewx.conf non-interactively
#                                (station location / lat / lon / altitude
#                                / units / driver via weewx's own
#                                reconfigure CLI) then deep-merges the
#                                user's overrides/weewx.conf. Runs before
#                                skyfield (skyfield's II_DEPS pulls it in)
#                                so the extension installs onto a
#                                fully-configured weewx.
#       weewx-webroot          — repoints the active backend's default
#                                site at /var/www/html/weewx so visitors
#                                hit the WeeWX page at "/"
#       weewx-site-ram         — mounts /var/www/html/weewx on tmpfs and
#                                installs a boot loading page (tmpfs,
#                                not zram — the site is just static
#                                HTML+PNG so compression adds nothing;
#                                name uses -ram for symmetry with
#                                feature-ram-logging / weewx-database-ram)
#       weewx-database-ram     — moves /var/lib/weewx to a zram-backed
#                                ext4 with validated hourly + shutdown
#                                snapshots; spares the SD card from
#                                WeeWX's continuous DB writes
#   - locale (deselectable), bash, motd
#   - skyfield (transitively pulls the weewx apt package + weewx-setup
#     via its II_DEPS)
#   - ram-logging — log2ram on a station Pi is a strict win, so it's
#     default-on under this role (still optional under other roles).
#
# motd-weather and motd-updates are intentionally NOT listed here even
# though both are useful — they're hidden children of motd and surface
# on motd's pick_addons sub-screen. Listing them in the role tier on
# top of that produced a duplicate-row UX. Surface them via the motd
# sub-screen; default state there comes from each child's own
# II_DEFAULT_SELECTED.
#
# OPTIONAL exposes Pi-tuning toggles (rconf, compressed-swap) — neither
# default-on.
#
# ROLE_CONFIG points at config/weewx.config so the in-menu editor sees
# the shared WEEWX_* defaults — the webroot / ramdisk knobs (WEB_DIR,
# TMPFS_SIZE, DB_DIR, DB_HDD_DIR, DB_ROTATIONS, DB_ZRAM_SIZE) AND the
# weewx-setup station knobs (STATION_LOCATION, LATITUDE, LONGITUDE,
# ALTITUDE, ALTITUDE_UNITS, STATION_TYPE, UNITS, REGISTER_STATION,
# STATION_URL). Without this, the editor would render blank rows for
# those keys since no per-feature config/<id>.config files exist for
# them.
#
# Still freestanding under scripts/ (not yet first-class features):
# weewx-nginx-ssl (subsumed by feature-webserver-ssl for cert issuance —
# only the weewx-specific config glue is left), weewx-onedrive-backup.

# === II_ROLE_BEGIN ===
ROLE_ID="weewx"
ROLE_TITLE="WeeWx"
ROLE_DESCRIPTION="Weather station software + Skyfield extension."
ROLE_FEATURES_REQUIRED="pkupd webserver"
ROLE_FEATURES_DEFAULT="weewx-setup weewx-webroot weewx-site-ram weewx-database-ram locale bash motd skyfield ram-logging"
ROLE_FEATURES_OPTIONAL="rconf compressed-swap"
ROLE_CONFIG="config/weewx.config"
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
