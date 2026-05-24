#!/bin/bash

# Module:      Update & Upgrade Packages
# Description: Refreshes the apt cache, runs the upgrade, then autoremove.
#              Each step is independently cached on its own timestamp
#              (PKUPD_UPDATE_RUN / PKUPD_UPGRADE_RUN / PKUPD_AUTOREMOVE_RUN
#              in $PATH_STATUS/pkupd.status.time). A step that succeeded
#              within the skip window is silently skipped by the lib.
#
#              Three editable knobs (config/pkupd.config, also on the in-menu
#              Edit Configuration screen):
#                PKUPD_UPGRADE_MODE   "dist-upgrade" (default — pulls new
#                                     packages incl. new-ABI kernels) or
#                                     "upgrade" (in-place only — never pulls
#                                     a kernel jump unprompted). "full-upgrade"
#                                     is accepted as an alias of dist-upgrade
#                                     (they're the identical apt operation).
#                PKUPD_SKIP_WINDOW_MIN  minutes; after a successful upgrade,
#                                     a re-run within this window skips the
#                                     apt steps. Default 60. 0 disables the
#                                     skip. A FAILED upgrade records no
#                                     timestamp, so a retry always re-runs.
#                PKUPD_AUTOREMOVE     "true" (default) runs apt-get autoremove
#                                     --purge after the upgrade; "false" skips
#                                     it. Independent of the upgrade depth.
#
#              --uninstall is a no-op with a notice — apt operations are not
#              individually reversible. Use apt directly to downgrade specific
#              packages if needed.
#
# Bumping II_VERSION updates the framework state record but does not bypass the
# skip window. To force a re-run, delete $PATH_STATUS/pkupd.status.time.

# === II_MANIFEST_BEGIN ===
II_ID="pkupd"
II_TITLE="Update & Upgrade Packages"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="conditional"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="PKUPD_UPGRADE_MODE PKUPD_SKIP_WINDOW_MIN PKUPD_AUTOREMOVE"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/verify.sh

# pkupd's own config, then any menu-config.sh overrides on top.
FILE_CONFIG_PKUPD="${PATH_CONFIG:-config}/pkupd.config"
[[ -f $FILE_CONFIG_PKUPD ]] && source "$FILE_CONFIG_PKUPD"
state_apply_menu_overrides
PKUPD_UPGRADE_MODE="${PKUPD_UPGRADE_MODE:-dist-upgrade}"
PKUPD_SKIP_WINDOW_MIN="${PKUPD_SKIP_WINDOW_MIN:-60}"
PKUPD_AUTOREMOVE="${PKUPD_AUTOREMOVE:-true}"

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    --verify)    MODE="verify" ;;
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

# The apt cache helpers gate "is this step still fresh?" on
# ACCEPTABLE_TIME_DELTA_SEC (seconds). Drive that from pkupd's own
# minutes-based skip window so the update/upgrade/autoremove trio shares
# one TTL. This assignment is process-local — each feature runs in its
# own `bash <path> --install`, so it doesn't leak to other installers.
if [[ $PKUPD_SKIP_WINDOW_MIN =~ ^[0-9]+$ ]]; then
  ACCEPTABLE_TIME_DELTA_SEC=$((PKUPD_SKIP_WINDOW_MIN * 60))
else
  log_warn "PKUPD_SKIP_WINDOW_MIN ('$PKUPD_SKIP_WINDOW_MIN') is not a number; falling back to 60."
  ACCEPTABLE_TIME_DELTA_SEC=3600
fi

do_verify() { verify_generic "$II_ID"; }

if [[ $MODE == "verify" ]]; then do_verify; exit $?; fi

if [[ $MODE == "uninstall" ]]; then
  log_info "pkupd is not reversible (apt update/upgrade/autoremove cannot be undone). Marking uninstalled."
  status_mark_uninstalled "$II_ID"
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious marked package updates as uninstalled."
  exit 0
fi

status_mark_started "$II_ID"
STATUS_FILE=$(status_file_for "$II_ID")

fail_step() {
  local what="$1"      # short description for log/status
  local user_msg="$2"  # for the colorized terminal summary
  local key="$3"       # per-step status key in pkupd.status, e.g. PKUPD_UPDATE_STEP
  local rc="$4"
  log_fail "$what failed." "$rc"
  status_set "$STATUS_FILE" "$key" "Error"
  status_set "$STATUS_FILE" "PKUPD_STATUS" "Error"
  status_mark_failed "$II_ID" "$what failed (code $rc)"
  echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not $user_msg. Error Code: $rc."
  exit "$rc"
}

log_info "Refreshing apt cache (apt-get update)."
apt_ensure_fresh; rc=$?
[[ $rc -ne 0 ]] && fail_step "apt-get update" "update package lists" "PKUPD_UPDATE_STEP" "$rc"
status_set "$STATUS_FILE" "PKUPD_UPDATE_STEP" "Completed"

case "$PKUPD_UPGRADE_MODE" in
  upgrade)
    log_info "Running apt-get upgrade (PKUPD_UPGRADE_MODE=upgrade — kernels held back)."
    apt_upgrade_fresh; rc=$?
    [[ $rc -ne 0 ]] && fail_step "apt-get upgrade" "upgrade packages" "PKUPD_UPGRADE_STEP" "$rc"
    ;;
  dist-upgrade|full-upgrade|"")
    # full-upgrade is the `apt` CLI's name for `apt-get dist-upgrade` —
    # identical operation, accepted as an alias.
    log_info "Running apt-get dist-upgrade (PKUPD_UPGRADE_MODE=$PKUPD_UPGRADE_MODE)."
    apt_dist_upgrade_fresh; rc=$?
    [[ $rc -ne 0 ]] && fail_step "apt-get dist-upgrade" "upgrade packages" "PKUPD_UPGRADE_STEP" "$rc"
    ;;
  *)
    log_warn "Unknown PKUPD_UPGRADE_MODE '$PKUPD_UPGRADE_MODE'; defaulting to dist-upgrade."
    log_info "Running apt-get dist-upgrade."
    apt_dist_upgrade_fresh; rc=$?
    [[ $rc -ne 0 ]] && fail_step "apt-get dist-upgrade" "upgrade packages" "PKUPD_UPGRADE_STEP" "$rc"
    ;;
esac
status_set "$STATUS_FILE" "PKUPD_UPGRADE_STEP" "Completed"

case "$PKUPD_AUTOREMOVE" in
  false)
    log_info "PKUPD_AUTOREMOVE=false — skipping apt-get autoremove."
    status_set "$STATUS_FILE" "PKUPD_AUTOREMOVE_STEP" "Skipped"
    ;;
  *)
    [[ $PKUPD_AUTOREMOVE != "true" ]] \
      && log_warn "Unknown PKUPD_AUTOREMOVE '$PKUPD_AUTOREMOVE'; defaulting to true (running autoremove)."
    log_info "Running apt-get autoremove."
    apt_autoremove_fresh; rc=$?
    [[ $rc -ne 0 ]] && fail_step "apt-get autoremove" "autoremove unused packages" "PKUPD_AUTOREMOVE_STEP" "$rc"
    status_set "$STATUS_FILE" "PKUPD_AUTOREMOVE_STEP" "Completed"
    ;;
esac

status_set "$STATUS_FILE" "PKUPD_STATUS" "Completed"
status_mark_complete "$II_ID" "$II_VERSION"
log_ok "Package update + upgrade complete."
echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully customized the package updates for the Raspberry Pi."
exit 0
