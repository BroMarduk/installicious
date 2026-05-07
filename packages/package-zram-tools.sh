#!/bin/bash

# Module:      zram-tools (apt package)
# Description: Apt-only wrapper for the upstream Debian/Pi OS zram-tools
#              package. Provides:
#                - the zramswap service (used by feature-zram on
#                  Bookworm-class systems where rpi-swap isn't shipped)
#                - the zramctl diagnostic CLI (useful even on Trixie /
#                  rpi-swap, where zramswap.service itself isn't used)
#
#              Idempotent: skipped when already recorded at II_VERSION.
#              --uninstall removes zram-tools only if it wasn't installed
#              before installicious touched the system.
#
#              Lifecycle (install / skip / uninstall, status tracking) is
#              handled entirely by lib/installer_apt.sh — this file is
#              only the manifest + dispatch.
#
#              feature-zram declares II_DEPS="zram-tools" so picking
#              "Compressed Swap (zram)" pulls this package in
#              automatically. Standalone install is also fine if you
#              just want the diagnostic CLI on a Trixie system.

# === II_MANIFEST_BEGIN ===
II_ID="zram-tools"
II_TITLE="zram-tools (compressed-RAM utilities)"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="zram-tools"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh

installer_apt_main "$@"
exit $?
