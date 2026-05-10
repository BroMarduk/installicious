#!/bin/bash

# WeeWx role - personal weather station software.
#
# REQUIRED installs the apt baseline plus the webserver parent feature,
# which triggers the apache/nginx/lighttpd/caddy radio sub-menu (nginx
# pre-selected). DEFAULT pulls in locale (deselectable), the MOTD bundle,
# and the SkyfieldAlmanac extension (which transitively pulls the weewx
# apt package via skyfield's II_DEPS). OPTIONAL exposes Pi-tuning toggles.
#
# motd-weather is default-on; the user must set MOTD_WEATHER_API_KEY and
# MOTD_WEATHER_LOC_CODE in the editor stage or its install will hard-fail.
#
# Pending feature wrappers (currently freestanding under scripts/, not
# yet first-class features): weewx-nginx (rewrite the chosen backend's
# default site to point at /var/www/html/weewx), weewx-database-ramdisk,
# weewx-onedrive-backup. When those land as features, add them to
# ROLE_FEATURES_OPTIONAL.

# === II_ROLE_BEGIN ===
ROLE_ID="weewx"
ROLE_TITLE="WeeWx"
ROLE_DESCRIPTION="WeeWx weather station software with SkyfieldAlmanac astronomy extension."
ROLE_FEATURES_REQUIRED="pkupd webserver"
ROLE_FEATURES_DEFAULT="locale bash motd skyfield motd-weather"
ROLE_FEATURES_OPTIONAL="rconf compressed-swap ram-logging motd-updates"
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
