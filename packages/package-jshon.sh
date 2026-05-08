#!/bin/bash

# Module:      jshon (apt package wrapper)
# Description: Apt-only wrapper for jshon — a tiny CLI for parsing JSON.
#              feature-motd-weather uses it to extract fields from the
#              AccuWeather API response inside the hourly cron job.
#
#              Idempotent: skipped when already recorded at II_VERSION.
#              --uninstall removes jshon only if it wasn't installed
#              before installicious touched the system.
#
#              Lifecycle (install / skip / uninstall, status tracking) is
#              handled entirely by lib/installer_apt.sh — this file is
#              only the manifest + dispatch.
#
#              feature-motd-weather declares II_DEPS="motd jshon" so
#              picking the weather add-on auto-pulls this package in.
#              Standalone install is fine if you want jshon for other
#              shell scripts on the system.

# === II_MANIFEST_BEGIN ===
II_ID="jshon"
II_TITLE="jshon (JSON parser for shell)"
II_CATEGORY="package"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="jshon"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh

installer_apt_main "$@"
exit $?
