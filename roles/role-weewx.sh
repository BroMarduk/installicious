#!/bin/bash

# WeeWx role - personal weather station software.
#
# REQUIRED installs the apt baseline plus the webserver parent feature,
# which triggers the apache/nginx/lighttpd/caddy radio sub-menu (nginx
# pre-selected). DEFAULT is listed RAM-stuff-first so the user's eye
# lands on the heavy weewx-specific decisions before the general ones,
# and so toggling them up-front communicates what extra packages will
# be pulled (zram-tools, sqlite3, etc.):
#   - the three weewx-specific wrappers:
#       weewx-webroot          — repoints the active backend's default
#                                site at /var/www/html/weewx so visitors
#                                hit the WeeWX page at "/"
#       weewx-site-zram        — mounts /var/www/html/weewx on tmpfs and
#                                installs a boot loading page (named
#                                -zram for symmetry with the DB wrapper;
#                                actual backing store is tmpfs since
#                                the site is just static HTML+PNG)
#       weewx-database-zram    — moves /var/lib/weewx to a zram-backed
#                                ext4 with validated hourly + shutdown
#                                snapshots; spares the SD card from
#                                WeeWX's continuous DB writes
#   - locale (deselectable), bash, motd
#   - skyfield (transitively pulls the weewx apt package via its II_DEPS)
#
# motd-weather and motd-updates are intentionally NOT listed here even
# though both are useful — they're hidden children of motd and surface
# on motd's pick_addons sub-screen. Listing them in the role tier on
# top of that produced a duplicate-row UX. Surface them via the motd
# sub-screen; default state there comes from each child's own
# II_DEFAULT_SELECTED.
#
# OPTIONAL exposes Pi-tuning toggles (rconf, compressed-swap,
# ram-logging) — none default-on.
#
# Still freestanding under scripts/ (not yet first-class features):
# weewx-nginx-ssl (subsumed by feature-webserver-ssl for cert issuance —
# only the weewx-specific config glue is left), weewx-onedrive-backup.

# === II_ROLE_BEGIN ===
ROLE_ID="weewx"
ROLE_TITLE="WeeWx"
ROLE_DESCRIPTION="Weather station software + Skyfield extension."
ROLE_FEATURES_REQUIRED="pkupd webserver"
ROLE_FEATURES_DEFAULT="weewx-webroot weewx-site-zram weewx-database-zram locale bash motd skyfield"
ROLE_FEATURES_OPTIONAL="rconf compressed-swap ram-logging"
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
