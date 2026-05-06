#!/bin/bash

# Module:      WeeWX Installer (stub)
# Description: Apt-only installer for the upstream Debian/Raspbian weewx
#              package. Idempotent: skipped when already recorded at
#              II_VERSION. --uninstall removes weewx only if it wasn't
#              installed before installicious touched the system.
#
#              v1 stub — installs the apt package and stops there. Station
#              configuration (lat/lon, station type, skin selection, service
#              enable, database path, etc.) is left for a follow-up pass.
#              Extensions like SkyfieldAlmanac (feature-skyfield.sh) layer on
#              top of this via II_DEPS and the wee_extension tool.
#
#              All lifecycle handling (install, skip-if-current, uninstall,
#              status tracking) is done by lib/installer_apt.sh — this file
#              is only the manifest + dispatch.

# === II_MANIFEST_BEGIN ===
II_ID="weewx"
II_TITLE="WeeWX weather software"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="weewx"
# === II_MANIFEST_END ===

source lib/installer_apt.sh
installer_apt_main "$@"
exit $?
