#!/bin/bash

# Module:      spi-tools (apt package)
# Description: Provides spi-config / spi-pipe — the userspace
#              diagnostic CLIs for the SPI bus. Pulled in automatically
#              when the user picks an SPI-RTC chip (each SPI chip-child
#              declares II_DEPS="spi-tools"). Also offered as an
#              optional toggle on pick_packages for users who want the
#              tools for unrelated reasons (SPI peripheral probing, etc.).
#
#              Idempotent: skipped when already recorded at II_VERSION.
#              --uninstall removes the apt package only if it wasn't
#              installed before installicious touched the system.
#
#              Lifecycle (install / skip / uninstall, status tracking) is
#              handled entirely by lib/installer_apt.sh — this file is
#              only the manifest + dispatch.

# === II_MANIFEST_BEGIN ===
II_ID="spi-tools"
II_TITLE="spi-tools (SPI diagnostic CLIs)"
II_CATEGORY="package"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="spi-tools"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh

installer_apt_main "$@"
exit $?
