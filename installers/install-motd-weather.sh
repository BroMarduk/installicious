#!/bin/bash

# Module:      MOTD Weather Add-on
# Description: Adds the hourly weather fetch to the MOTD. Installs the jshon
#              apt package and renders motd-current-weather.sh into
#              /etc/cron.hourly/, which writes the current conditions to a
#              results file the base motd.sh / motd-small.sh banner reads.
#
#              II_DEPS="motd" so the scheduler auto-pulls the base MOTD
#              installer into the queue whenever weather is selected on its
#              own. The Pillar-6 hardened scheduler will refuse to start the
#              run if install-motd.sh is somehow missing.
#
#              Symmetric --uninstall: removes the cron job, then reverts
#              jshon (only if we installed it).

# === II_MANIFEST_BEGIN ===
II_ID="motd-weather"
II_TITLE="MOTD weather (hourly current conditions)"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS="motd"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_APT_PACKAGES="jshon"
II_EDITABLE_CONFIG="MOTD_WEATHER_LOC_CODE"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/installer_apt.sh

FILE_CONFIG_MOTD="${PATH_CONFIG:-config}/motd.config"
[[ -f $FILE_CONFIG_MOTD ]] && source "$FILE_CONFIG_MOTD"
state_apply_menu_overrides
MOTD_NAME="${MOTD_NAME:-dannet}"
MOTD_WEATHER_LOC_CODE="${MOTD_WEATHER_LOC_CODE:-}"
MOTD_IP_URL="${MOTD_IP_URL:-https://api.ipify.org}"
MOTD_SMALL_SIZE="${MOTD_SMALL_SIZE:-79}"

CRON_HOURLY_WEATHER="/etc/cron.hourly/motd-current-weather"

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

render_resource() {
  local src="$1" dest="$2"
  local tmp
  tmp=$(mktemp) || return 1
  sed -e "s|%%MOTD_NAME%%|${MOTD_NAME}|g" \
      -e "s|%%MOTD_IP_URL%%|${MOTD_IP_URL}|g" \
      -e "s|%%MOTD_WEATHER_LOC_CODE%%|${MOTD_WEATHER_LOC_CODE}|g" \
      -e "s|%%MOTD_SMALL_SIZE%%|${MOTD_SMALL_SIZE}|g" \
      "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m 0755 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"; then
    log_info "MOTD weather already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # ---- apt deps (with per-package pre-state) ----
  log_info "Ensuring apt deps: $II_APT_PACKAGES."
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt deps install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install jshon. Error Code: $rc."
    return $rc
  fi

  # ---- hourly cron ----
  log_info "Installing $CRON_HOURLY_WEATHER."
  render_resource "${PATH_RESOURCES:-resources}/motd-current-weather.sh" "$CRON_HOURLY_WEATHER" \
    || { log_fail "Failed to install hourly weather cron."; status_mark_failed "$II_ID" "weather cron install failed"; return 1; }

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"
  log_ok "MOTD weather installed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed the MOTD weather add-on."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "MOTD weather already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] MOTD weather is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for motd-weather; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  if [[ -e $CRON_HOURLY_WEATHER ]]; then
    log_info "Removing $CRON_HOURLY_WEATHER."
    sudo rm -f "$CRON_HOURLY_WEATHER"
  fi

  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "MOTD weather uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled the MOTD weather add-on."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
