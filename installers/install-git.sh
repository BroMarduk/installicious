#!/bin/bash

# Module:      GIT Installer
# Description: Installs Git source control. Idempotent: a no-op if git is already
#              installed at the recorded II_VERSION. Upgrades are handled by the
#              pkupd installer, not here.
#
#              On install we record whether git was already present pre-install
#              so --uninstall can correctly leave it alone if we didn't add it.
#
#              --uninstall removes git (only if we installed it) and clears state.
#
# Bump II_VERSION to force a re-run on the next installicious run.

# === II_MANIFEST_BEGIN ===
II_ID="git"
II_TITLE="Git source control"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===

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
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

STATUS_FILE=$(status_file_for "$II_ID")

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "Git already installed at recorded version. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # Capture pre-state so uninstall knows whether to remove the package.
  if apt_is_installed git; then
    status_set "$STATUS_FILE" "GIT_FW_PRE_INSTALLED" "true"
  else
    status_set "$STATUS_FILE" "GIT_FW_PRE_INSTALLED" "false"
  fi

  log_info "Ensuring git is installed."
  apt_ensure_installed git
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log_fail "Failed to install git." "$rc"
    status_mark_failed "$II_ID" "apt-get install git failed (code $rc)"
    status_set "$STATUS_FILE" "GIT_STATUS" "Error"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Git. Error Code: $rc."
    return $rc
  fi

  log_ok "Git installed."
  status_mark_complete "$II_ID" "$II_VERSION"
  status_set "$STATUS_FILE" "GIT_STATUS" "Completed"
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed Git."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Git is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for git; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  local pre_installed
  pre_installed=$(status_get "$STATUS_FILE" "GIT_FW_PRE_INSTALLED")
  if [[ $pre_installed == "true" ]]; then
    log_info "Git was installed before installicious touched it; leaving the package in place."
  else
    log_info "Removing git (we installed it)."
    apt_remove git
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      log_fail "Failed to remove git." "$rc"
      status_mark_failed "$II_ID" "apt remove git failed (code $rc)"
      status_set "$STATUS_FILE" "GIT_STATUS" "Error"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not remove Git. Error Code: $rc."
      return $rc
    fi
  fi

  status_mark_uninstalled "$II_ID"
  status_set "$STATUS_FILE" "GIT_STATUS" "Uninstalled"
  log_ok "Git uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled Git."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
