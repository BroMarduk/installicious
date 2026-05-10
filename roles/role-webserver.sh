#!/bin/bash

# Web Server role - generic Pi-as-web-server configuration.
#
# REQUIRED installs the apt baseline plus the webserver parent feature,
# which triggers a single-select sub-menu (apache / nginx / lighttpd /
# caddy). DEFAULT pulls in locale + the basic banner. OPTIONAL exposes
# Pi-tuning toggles.
#
# Picking webserver as REQUIRED guarantees the radio sub-menu fires
# even though the user can't deselect the parent. nginx is pre-selected
# in the radio (II_DEFAULT_SELECTED="on") since it's the most common Pi
# web stack and what WeeWx already builds on.

# === II_ROLE_BEGIN ===
ROLE_ID="webserver"
ROLE_TITLE="Web Server"
ROLE_DESCRIPTION="Generic Pi web server. Pick one HTTP backend on the next screen; configure document root, server name, and port via the editor."
ROLE_FEATURES_REQUIRED="pkupd webserver"
ROLE_FEATURES_DEFAULT="locale bash motd"
ROLE_FEATURES_OPTIONAL="rconf compressed-swap ram-logging motd-updates"
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
