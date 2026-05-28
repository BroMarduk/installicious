#!/bin/bash

# Module:      i2c-tools (apt package)
# Description: Provides i2cdetect / i2cget / i2cset — the userspace
#              diagnostic CLIs for the I²C bus. Pulled in automatically
#              when the user picks an I²C-RTC chip (each I²C chip-child
#              declares II_DEPS="i2c-tools"). Also offered as an
#              optional toggle on pick_packages for users who want the
#              tools for unrelated reasons (sensor probing, etc.).
#
#              Idempotent: skipped when already recorded at II_VERSION.
#              --uninstall removes the apt package only if it wasn't
#              installed before installicious touched the system.
#
#              Lifecycle (install / skip / uninstall, status tracking) is
#              handled entirely by lib/installer_apt.sh — this file is
#              only the manifest + dispatch.

# === II_MANIFEST_BEGIN ===
II_ID="i2c-tools"
II_TITLE="i2c-tools (I²C diagnostic CLIs)"
II_CATEGORY="package"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="i2c-tools"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh

installer_apt_main "$@"
exit $?
