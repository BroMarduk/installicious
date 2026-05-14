#!/bin/bash

# Module:      WeeWX Installer
# Description: Installs the upstream WeeWX apt package. WeeWX is NOT in the
#              Debian / Raspberry Pi OS archive (RPi OS doesn't mirror it),
#              so this installer first configures weewx.com's own apt
#              repository, then hands off to the generic apt installer.
#
#              Repo setup (via lib/apt.sh's apt_add_repo, idempotent):
#                - dearmors weewx.com's signing key into
#                  /etc/apt/trusted.gpg.d/weewx.gpg
#                - writes /etc/apt/sources.list.d/weewx.list
#                - refreshes the apt cache
#              The "buster" token in the repo line is weewx.com's static
#              suite label for their python3 packages — it is NOT tied to
#              Debian Buster and is correct on Bookworm / Trixie.
#
#              Idempotent: skipped when already recorded at II_VERSION.
#              --uninstall removes the weewx package only if it wasn't
#              installed before installicious touched the system; it
#              intentionally LEAVES the apt repo + key in place (removing
#              a repo is more invasive than removing a package, and a
#              lingering unused repo is harmless — a later re-install is
#              then a no-op on the repo-setup step).
#
#              Station configuration (lat/lon, station type, skins, etc.)
#              is handled separately by features/feature-weewx-setup.sh;
#              extensions like SkyfieldAlmanac layer on via II_DEPS.

# === II_MANIFEST_BEGIN ===
II_ID="weewx"
II_TITLE="WeeWX weather software"
II_CATEGORY="package"
II_VERSION="2"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="weewx"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/apt.sh
source lib/installer_apt.sh

WEEWX_APT_KEY_URL="https://weewx.com/keys.html"
WEEWX_APT_REPO_LINE="deb [arch=all] https://weewx.com/apt/python3 buster main"

# Only --install needs the repo configured. --uninstall and bare status
# queries don't touch apt sources. (A missing arg defaults to install,
# matching installer_apt_main's own default.)
if [[ "${1:-}" == "--install" || -z "${1:-}" ]]; then
  if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
    FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
  else
    FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
  fi
  log_init "$II_TITLE" "$FILE_LOG_INSTALLER"
  log_info "Configuring the weewx.com apt repository (weewx isn't in the Debian/RPi OS archive)."
  if ! apt_add_repo "weewx" "$WEEWX_APT_KEY_URL" "$WEEWX_APT_REPO_LINE"; then
    log_fail "Failed to configure the weewx.com apt repository."
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not set up the weewx.com apt repository."
    exit 1
  fi
fi

installer_apt_main "$@"
exit $?
