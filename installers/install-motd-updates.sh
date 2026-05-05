#!/bin/bash

# Module:      MOTD Update-Count Add-on
# Description: Adds the upgradable-package count to the login MOTD. Drops a
#              cron script at /etc/cron.hourly/motd-current-updates that
#              runs `apt list --upgradable`, writes the count (or empty
#              when zero) to /etc/motd.d/<MOTD_NAME>/results-updates, and
#              wires an apt.conf.d hook that re-runs the same script after
#              every dpkg / apt operation so the MOTD reflects the current
#              count immediately rather than waiting for the next hourly tick.
#
#              No apt deps — uses the system apt directly.
#
#              II_DEPS="motd" so the scheduler auto-pulls the base MOTD
#              installer into the queue whenever updates is selected on its
#              own. Surfaces from motd's add-on sub-menu via motd's
#              II_OPTIONAL_GROUP rather than as a standalone Custom-menu
#              item.
#
#              Symmetric --uninstall: removes the cron and the apt.conf.d
#              drop-in.

# === II_MANIFEST_BEGIN ===
II_ID="motd-updates"
II_TITLE="MOTD update count (apt)"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS="motd"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh

FILE_CONFIG_MOTD="${PATH_CONFIG:-config}/motd.config"
[[ -f $FILE_CONFIG_MOTD ]] && source "$FILE_CONFIG_MOTD"
state_apply_menu_overrides
MOTD_NAME="${MOTD_NAME:-dannet}"

CRON_HOURLY_UPDATES="/etc/cron.hourly/motd-current-updates"
APT_HOOK="/etc/apt/apt.conf.d/80updaterefresh"

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

# render_resource <src> <dest> [<mode>]
# Copy a resources/* file into place with %%TOKEN%% substitution. Mode
# defaults to 0755; pass an explicit mode for system-config files (e.g.
# apt.conf.d entries, which should be 0644 root:root).
render_resource() {
  local src="$1" dest="$2" mode="${3:-0755}"
  local tmp
  tmp=$(mktemp) || return 1
  # Only %%MOTD_NAME%% appears in motd-current-updates.sh; the apt.conf.d
  # drop-in has no tokens to substitute.
  sed -e "s|%%MOTD_NAME%%|${MOTD_NAME}|g" \
      "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"; then
    log_info "MOTD updates already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # ---- hourly cron (no `.sh` so run-parts doesn't skip it) ----
  log_info "Installing $CRON_HOURLY_UPDATES."
  render_resource "${PATH_RESOURCES:-resources}/motd-current-updates.sh" "$CRON_HOURLY_UPDATES" 0755 \
    || { log_fail "Failed to install hourly updates cron."; status_mark_failed "$II_ID" "updates cron install failed"; return 1; }

  # ---- apt.conf.d hook so the count refreshes after every apt/dpkg op ----
  log_info "Installing $APT_HOOK."
  render_resource "${PATH_RESOURCES:-resources}/motd-update-refresh.conf" "$APT_HOOK" 0644 \
    || { log_fail "Failed to install apt hook."; status_mark_failed "$II_ID" "apt hook install failed"; return 1; }

  # ---- seed results-updates by running the cron once now ----
  # Without this the first login until the next apt/dpkg op or hourly tick
  # would show no update count. Failures (no network, apt index stale,
  # apt-list permission issue) are warned but don't fail the install.
  if [[ -x $CRON_HOURLY_UPDATES ]]; then
    log_info "Running $CRON_HOURLY_UPDATES once to capture initial update count."
    if ! sudo "$CRON_HOURLY_UPDATES"; then
      log_warn "Initial update-count fetch failed; cron will retry on the next apt op or hourly tick."
    fi
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"
  log_ok "MOTD updates installed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed the MOTD updates add-on."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "MOTD updates already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] MOTD updates is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for motd-updates; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  if [[ -e $APT_HOOK ]]; then
    log_info "Removing $APT_HOOK."
    sudo rm -f "$APT_HOOK"
  fi
  if [[ -e $CRON_HOURLY_UPDATES ]]; then
    log_info "Removing $CRON_HOURLY_UPDATES."
    sudo rm -f "$CRON_HOURLY_UPDATES"
  fi

  status_mark_uninstalled "$II_ID"
  log_ok "MOTD updates uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled the MOTD updates add-on."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
