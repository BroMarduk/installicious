#!/bin/bash

# Module:      Update & Upgrade Packages
# Description: Refreshes the apt cache, runs dist-upgrade, then autoremove.
#              Each step is independently cached on its own timestamp
#              (PKUPD_UPDATE_RUN / PKUPD_UPGRADE_RUN / PKUPD_AUTOREMOVE_RUN
#              in $PATH_STATUS/pkupd.status.time). A step that ran within
#              ACCEPTABLE_TIME_DELTA_SEC is silently skipped by the lib.
#
# Bumping II_VERSION updates the framework state record but does not bypass the
# cache TTL. To force a re-run, delete $PATH_STATUS/pkupd.status.time.

II_VERSION="1"
INSTALLER_ID="pkupd"
MODULE="Update & Upgrade Packages"

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

status_mark_started "$INSTALLER_ID"
STATUS_FILE=$(status_file_for "$INSTALLER_ID")

fail_step() {
  local what="$1"      # short description for log/status
  local user_msg="$2"  # for the colorized terminal summary
  local key="$3"       # legacy status key, e.g. PKUPD_UPDATE
  local rc="$4"
  log_fail "$what failed." "$rc"
  status_set "$STATUS_FILE" "$key" "Error"
  status_set "$STATUS_FILE" "PKUPD_STATUS" "Error"
  status_mark_failed "$INSTALLER_ID" "$what failed (code $rc)"
  echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not $user_msg. Error Code: $rc."
  exit "$rc"
}

log_info "Refreshing apt cache (apt-get update)."
apt_ensure_fresh; rc=$?
[[ $rc -ne 0 ]] && fail_step "apt-get update" "update package lists" "PKUPD_UPDATE" "$rc"
status_set "$STATUS_FILE" "PKUPD_UPDATE" "Completed"

log_info "Running apt-get dist-upgrade."
apt_dist_upgrade_fresh; rc=$?
[[ $rc -ne 0 ]] && fail_step "apt-get dist-upgrade" "upgrade packages" "PKUPD_UPGRADE" "$rc"
status_set "$STATUS_FILE" "PKUPD_UPGRADE" "Completed"

log_info "Running apt-get autoremove."
apt_autoremove_fresh; rc=$?
[[ $rc -ne 0 ]] && fail_step "apt-get autoremove" "autoremove unused packages" "PKUPD_AUTOREMOVE" "$rc"
status_set "$STATUS_FILE" "PKUPD_AUTOREMOVE" "Completed"

status_set "$STATUS_FILE" "PKUPD_STATUS" "Completed"
status_mark_complete "$INSTALLER_ID" "$II_VERSION"
log_ok "Package update + upgrade + autoremove complete."
echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully customized the package updates for the Raspberry Pi."
exit 0
