#!/bin/bash

# Module:      PIP Installer
# Description: Installs pip for Python 3 via the python3-pip apt package.
#              Idempotent: a no-op if already installed at the recorded
#              II_VERSION. Upgrades are handled by the pkupd installer.
#
# Bump II_VERSION to force a re-run on the next installicious run.

II_VERSION="1"
INSTALLER_ID="pip"
MODULE="PIP Installer"

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$MODULE" "$FILE_LOG_INSTALLER"

if status_should_skip "$INSTALLER_ID" "$II_VERSION"; then
  log_info "Pip already installed at recorded version. Skipping."
  exit 0
fi

status_mark_started "$INSTALLER_ID"

log_info "Ensuring python3-pip is installed."
apt_ensure_installed python3-pip
rc=$?
if [[ $rc -ne 0 ]]; then
  log_fail "Failed to install python3-pip." "$rc"
  status_mark_failed "$INSTALLER_ID" "apt-get install python3-pip failed (code $rc)"
  # Backward-compat shim for scripts/process-software.sh; retires with Pillar 2.
  status_set "$(status_file_for "$INSTALLER_ID")" "PIP_STATUS" "Error"
  echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Pip. Error Code: $rc."
  exit $rc
fi

log_ok "Pip installed."
status_mark_complete "$INSTALLER_ID" "$II_VERSION"
# Backward-compat shim for scripts/process-software.sh; retires with Pillar 2.
status_set "$(status_file_for "$INSTALLER_ID")" "PIP_STATUS" "Completed"
echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed Pip."
exit 0
