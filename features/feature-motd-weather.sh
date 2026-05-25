#!/bin/bash

# Module:      MOTD Weather Add-on
# Description: Adds the hourly weather fetch to the MOTD. Renders
#              motd-current-weather.sh into /etc/cron.hourly/, which
#              writes the current conditions to a results file the
#              base motd.sh / motd-small.sh banner reads.
#
#              II_DEPS="motd jshon":
#                motd  - base MOTD installer; scheduler auto-pulls it
#                        when weather is selected on its own
#                jshon - tiny JSON-parser CLI used inside the cron
#                        script to pluck fields from the AccuWeather
#                        response. Lives as packages/package-jshon.sh
#                        so the apt install + symmetric --uninstall
#                        revert is owned there, not here.
#
#              The Pillar-6 hardened scheduler will refuse to start the
#              run if either dependency manifest is missing.
#
#              Symmetric --uninstall: removes the cron job. The jshon
#              package's own --uninstall handles its apt-revert.

# === II_MANIFEST_BEGIN ===
II_ID="motd-weather"
II_TITLE="MOTD weather (hourly current conditions)"
II_CATEGORY="feature"
II_VERSION="2"
II_DEPS="motd jshon"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_EDITABLE_CONFIG="MOTD_WEATHER_LOC_CODE MOTD_WEATHER_API_KEY MOTD_WEATHER_ZIP_CODE"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/verify.sh

FILE_CONFIG_MOTD="${PATH_CONFIG:-config}/motd.config"
[[ -f $FILE_CONFIG_MOTD ]] && source "$FILE_CONFIG_MOTD"
state_apply_menu_overrides
MOTD_NAME="${MOTD_NAME:-dannet}"
MOTD_WEATHER_LOC_CODE="${MOTD_WEATHER_LOC_CODE:-}"
MOTD_WEATHER_API_KEY="${MOTD_WEATHER_API_KEY:-}"

CRON_HOURLY_WEATHER="/etc/cron.hourly/motd-current-weather"

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

STATUS_FILE=$(status_file_for "$II_ID")

render_resource() {
  local src="$1" dest="$2"
  local tmp
  tmp=$(mktemp) || return 1
  # Only substitute tokens that actually appear in motd-current-weather.sh.
  sed -e "s|%%MOTD_NAME%%|${MOTD_NAME}|g" \
      -e "s|%%MOTD_WEATHER_LOC_CODE%%|${MOTD_WEATHER_LOC_CODE}|g" \
      -e "s|%%MOTD_WEATHER_API_KEY%%|${MOTD_WEATHER_API_KEY}|g" \
      "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m 0700 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"; then
    log_info "MOTD weather already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # ---- safety check: refuse to install without an AccuWeather API key ----
  # The fetch script bakes the bearer token into the rendered cron file. An
  # empty key means the cron will fail at every run; an unset key being baked
  # into a file at /etc/cron.hourly/ also looks like a half-finished install.
  # Hard-fail here so the user goes back and fills it in via the menu editor.
  if [[ -z $MOTD_WEATHER_API_KEY ]]; then
    log_fail "MOTD_WEATHER_API_KEY is empty — set it via the menu config editor before installing motd-weather."
    status_mark_failed "$II_ID" "API key not set"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious cannot install motd-weather: AccuWeather API key is not set."
    echo -e "         Re-run installicious and set MOTD_WEATHER_API_KEY in the configuration editor."
    return 2
  fi
  if [[ -z $MOTD_WEATHER_LOC_CODE ]]; then
    log_fail "MOTD_WEATHER_LOC_CODE is empty — set it via the menu config editor before installing motd-weather."
    status_mark_failed "$II_ID" "Location code not set"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious cannot install motd-weather: AccuWeather location code is not set."
    echo -e "         Re-run installicious and set MOTD_WEATHER_LOC_CODE in the configuration editor."
    return 2
  fi

  # jshon is pulled in via II_DEPS — packages/package-jshon.sh runs
  # before us in the scheduler order and handles apt install + its
  # own pre-install state record. No apt step here anymore.

  # ---- hourly cron ----
  log_info "Installing $CRON_HOURLY_WEATHER."
  render_resource "${PATH_RESOURCES:-resources}/motd-current-weather.sh" "$CRON_HOURLY_WEATHER" \
    || { log_fail "Failed to install hourly weather cron."; status_mark_failed "$II_ID" "weather cron install failed"; return 1; }

  # ---- seed the weather-results file by running the cron once now ----
  # Without this, the first login until the hourly cron fires would show no
  # weather. Failures (API down, bad key, network) are warned but don't fail
  # the install — the cron will retry next hour.
  if [[ -x $CRON_HOURLY_WEATHER ]]; then
    log_info "Running $CRON_HOURLY_WEATHER once to capture initial weather."
    if ! sudo "$CRON_HOURLY_WEATHER"; then
      log_warn "Initial weather fetch failed; cron will retry next hour."
    fi
  fi

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

  # jshon apt-revert is owned by packages/package-jshon.sh — its
  # --uninstall checks its own pre-install record and apt-removes
  # only if it wasn't there before installicious touched the system.

  status_mark_uninstalled "$II_ID"
  log_ok "MOTD weather uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled the MOTD weather add-on."
  return 0
}

do_verify() { verify_generic "$II_ID"; }

if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "verify" ]]; then
  do_verify
else
  do_uninstall
fi
exit $?
