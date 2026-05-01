#!/bin/bash

# Module:      GIT Installer
# Description: Installs Git source control. Idempotent: a no-op if git is already
#              installed at the recorded II_VERSION. Upgrades are handled by the
#              pkupd installer, not here.
#
# Bump II_VERSION to force a re-run on the next installicious run.

II_VERSION="1"
INSTALLER_ID="git"
MODULE="GIT Installer"

# Load framework config and helper libs. cwd is expected to be the project
# root, which is how installicious.sh invokes installers.
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
  log_info "Git already installed at recorded version. Skipping."
  exit 0
fi

status_mark_started "$INSTALLER_ID"

log_info "Ensuring git is installed."
apt_ensure_installed git
rc=$?
if [[ $rc -ne 0 ]]; then
  log_fail "Failed to install git." "$rc"
  status_mark_failed "$INSTALLER_ID" "apt-get install git failed (code $rc)"
  # Backward-compat shim for scripts/process-software.sh; retires with Pillar 2.
  status_set "$(status_file_for "$INSTALLER_ID")" "GIT_STATUS" "Error"
  echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Git. Error Code: $rc."
  exit $rc
fi

log_ok "Git installed."
status_mark_complete "$INSTALLER_ID" "$II_VERSION"
# Backward-compat shim for scripts/process-software.sh; retires with Pillar 2.
status_set "$(status_file_for "$INSTALLER_ID")" "GIT_STATUS" "Completed"
echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed Git."
exit 0
