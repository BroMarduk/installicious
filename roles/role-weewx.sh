#!/bin/bash

# WeeWx role - personal weather station software.
#
# REQUIRED installs the apt baseline plus the webserver parent feature,
# which triggers the apache/nginx/lighttpd/caddy radio sub-menu (nginx
# pre-selected). DEFAULT pulls in:
#   - locale (deselectable)
#   - the MOTD bundle (motd + motd-weather)
#   - the SkyfieldAlmanac extension (which transitively pulls the weewx
#     apt package via skyfield's II_DEPS)
#   - the three weewx-specific wrappers:
#       weewx-webroot          — repoints the active backend's default
#                                site at /var/www/html/weewx so visitors
#                                hit the WeeWX page at "/"
#       weewx-site-ramdisk     — mounts /var/www/html/weewx on tmpfs and
#                                installs a boot loading page
#       weewx-database-ramdisk — moves /var/lib/weewx to a zram-backed
#                                ext4 with validated hourly + shutdown
#                                snapshots; spares the SD card from
#                                WeeWX's continuous DB writes
#
# OPTIONAL exposes Pi-tuning toggles. motd-weather is default-on; the
# user must set MOTD_WEATHER_API_KEY and MOTD_WEATHER_LOC_CODE in the
# editor stage or its install will hard-fail.
#
# Still freestanding under scripts/ (not yet first-class features):
# weewx-nginx-ssl (subsumed by feature-webserver-ssl for cert issuance —
# only the weewx-specific config glue is left), weewx-onedrive-backup.

# === II_ROLE_BEGIN ===
ROLE_ID="weewx"
ROLE_TITLE="WeeWx"
ROLE_DESCRIPTION="Weather station software + Skyfield extension."
ROLE_FEATURES_REQUIRED="pkupd webserver"
ROLE_FEATURES_DEFAULT="locale bash motd skyfield motd-weather weewx-webroot weewx-site-ramdisk weewx-database-ramdisk"
ROLE_FEATURES_OPTIONAL="rconf compressed-swap ram-logging motd-updates"
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
