#!/bin/bash

# Module:      PIP Installer
# Description: Installs pip for Python 3 via the python3-pip apt package.
#              Idempotent: a no-op if already installed at the recorded
#              II_VERSION. Upgrades are handled by the pkupd installer.
#
#              On install we record whether python3-pip was already present so
#              --uninstall can leave it in place when we didn't add it.
#
#              --uninstall removes python3-pip (only if we installed it) and
#              clears state.
#
# Bump II_VERSION to force a re-run on the next installicious run.

II_VERSION="1"
INSTALLER_ID="pip"
MODULE="PIP Installer"

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$MODULE" "$FILE_LOG_INSTALLER"

STATUS_FILE=$(status_file_for "$INSTALLER_ID")

do_install() {
  if status_should_skip "$INSTALLER_ID" "$II_VERSION"; then
    log_info "Pip already installed at recorded version. Skipping."
    return 0
  fi
  status_mark_started "$INSTALLER_ID"

  if apt_is_installed python3-pip; then
    status_set "$STATUS_FILE" "PIP_FW_PRE_INSTALLED" "true"
  else
    status_set "$STATUS_FILE" "PIP_FW_PRE_INSTALLED" "false"
  fi

  log_info "Ensuring python3-pip is installed."
  apt_ensure_installed python3-pip
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log_fail "Failed to install python3-pip." "$rc"
    status_mark_failed "$INSTALLER_ID" "apt-get install python3-pip failed (code $rc)"
    status_set "$STATUS_FILE" "PIP_STATUS" "Error"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Pip. Error Code: $rc."
    return $rc
  fi

  log_ok "Pip installed."
  status_mark_complete "$INSTALLER_ID" "$II_VERSION"
  status_set "$STATUS_FILE" "PIP_STATUS" "Completed"
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed Pip."
  return 0
}

do_uninstall() {
  case "$(status_state "$INSTALLER_ID")" in
    uninstalled)
      log_info "Already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Pip is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for pip; nothing to revert."
      status_mark_uninstalled "$INSTALLER_ID"
      return 0
      ;;
  esac

  local pre_installed
  pre_installed=$(status_get "$STATUS_FILE" "PIP_FW_PRE_INSTALLED")
  if [[ $pre_installed == "true" ]]; then
    log_info "python3-pip was installed before installicious touched it; leaving the package in place."
  else
    log_info "Removing python3-pip (we installed it)."
    apt_remove python3-pip
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      log_fail "Failed to remove python3-pip." "$rc"
      status_mark_failed "$INSTALLER_ID" "apt remove python3-pip failed (code $rc)"
      status_set "$STATUS_FILE" "PIP_STATUS" "Error"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not remove Pip. Error Code: $rc."
      return $rc
    fi
  fi

  status_mark_uninstalled "$INSTALLER_ID"
  status_set "$STATUS_FILE" "PIP_STATUS" "Uninstalled"
  log_ok "Pip uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled Pip."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
