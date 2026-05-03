#!/bin/bash

# Module:      Pip Installer
# Description: Apt-only installer for python3-pip. Idempotent: skipped when
#              already recorded at II_VERSION. --uninstall removes the package
#              only if it wasn't installed before installicious touched the
#              system.
#
#              All lifecycle handling (install, skip-if-current, uninstall,
#              status tracking) is done by lib/installer_apt.sh — this file
#              is only the manifest + dispatch.

# === II_MANIFEST_BEGIN ===
II_ID="pip"
II_TITLE="Python pip"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="python3-pip"
# === II_MANIFEST_END ===

source lib/installer_apt.sh
installer_apt_main "$@"
exit $?
