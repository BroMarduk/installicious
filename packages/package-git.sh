#!/bin/bash

# Module:      Git Installer
# Description: Apt-only installer for git. Idempotent: skipped when already
#              recorded at II_VERSION. --uninstall removes git only if it
#              wasn't installed before installicious touched the system.
#
#              All lifecycle handling (install, skip-if-current, uninstall,
#              status tracking) is done by lib/installer_apt.sh — this file
#              is only the manifest + dispatch.

# === II_MANIFEST_BEGIN ===
II_ID="git"
II_TITLE="Git source control"
II_CATEGORY="package"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="git"
# === II_MANIFEST_END ===

source lib/installer_apt.sh
installer_apt_main "$@"
exit $?
