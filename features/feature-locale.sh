#!/bin/bash

# Module:      Set Localizations
# Description: Applies system locale, timezone, keyboard layout/model, and
#              WiFi country from config/locale.config. Each value is
#              optional — leaving a value blank in the config skips that
#              piece and preserves whatever the RPi Imager set.
#
#              Uses raspi-config's nonint commands where they exist:
#                LOCALE_LANG            -> do_change_locale
#                LOCALE_TIMEZONE        -> do_change_timezone
#                LOCALE_KEYBOARD_LAYOUT -> do_configure_keyboard
#                LOCALE_WIFI_COUNTRY    -> do_wifi_country
#              Keyboard model has no nonint command, so we sed
#              /etc/default/keyboard's XKBMODEL line directly.
#
#              II_DEFAULT_SELECTED="on" so this is pre-checked in the
#              Custom-flow checklist that all roles currently route
#              through. Once roles grow real ROLE_FEATURES_DEFAULT lists
#              they should include "locale" there too.
#
# Reboot:      II_REQUIRES_REBOOT="never". Locale / keyboard / timezone /
#              wifi-country changes take effect for new processes — they
#              don't need a system reboot. (Already-running shells see the
#              old locale until they re-source their profile, but that's
#              normal.)

# === II_MANIFEST_BEGIN ===
II_ID="locale"
II_TITLE="Set Localizations (locale, timezone, keyboard, WiFi country)"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="LOCALE_LANG LOCALE_TIMEZONE LOCALE_KEYBOARD_LAYOUT LOCALE_KEYBOARD_MODEL LOCALE_WIFI_COUNTRY"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
[[ -f config/locale.config ]] && source config/locale.config
state_apply_menu_overrides

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

KEYBOARD_FILE="${KEYBOARD_FILE:-/etc/default/keyboard}"
RASPI_CONFIG_BIN="${RASPI_CONFIG_BIN:-/usr/bin/raspi-config}"

# All four nonint helpers run under `sudo env LC_ALL=C LANG=C ...` so any
# perl / locale tools they spawn fall back to C immediately. Without this,
# if the user's shell inherited a LANG that hasn't been generated on the
# system yet (e.g. RPi Imager's en_GB.UTF-8 default before do_change_locale
# has had a chance to run), every child process emits "Cannot set LC_CTYPE
# to default locale" warnings — harmless, but a wall of noise.
_RC_ENV=(env LC_ALL=C LANG=C)

_apply_locale() {
  [[ -z $LOCALE_LANG ]] && { log_info "LOCALE_LANG blank; preserving system default."; return 0; }
  log_info "Setting locale to $LOCALE_LANG."
  if sudo "${_RC_ENV[@]}" "$RASPI_CONFIG_BIN" nonint do_change_locale "$LOCALE_LANG"; then
    status_set "$STATUS_FILE" "LOCALE_FW_LOCALE_APPLIED" "$LOCALE_LANG"
    log_ok "Locale set to $LOCALE_LANG."
  else
    log_warn "raspi-config do_change_locale failed for $LOCALE_LANG (rc=$?); continuing."
  fi
}

_apply_timezone() {
  [[ -z $LOCALE_TIMEZONE ]] && { log_info "LOCALE_TIMEZONE blank; preserving system default."; return 0; }
  log_info "Setting timezone to $LOCALE_TIMEZONE."
  if sudo "${_RC_ENV[@]}" "$RASPI_CONFIG_BIN" nonint do_change_timezone "$LOCALE_TIMEZONE"; then
    status_set "$STATUS_FILE" "LOCALE_FW_TIMEZONE_APPLIED" "$LOCALE_TIMEZONE"
    log_ok "Timezone set to $LOCALE_TIMEZONE."
  else
    log_warn "raspi-config do_change_timezone failed for $LOCALE_TIMEZONE (rc=$?); continuing."
  fi
}

_apply_keyboard_layout() {
  [[ -z $LOCALE_KEYBOARD_LAYOUT ]] && { log_info "LOCALE_KEYBOARD_LAYOUT blank; preserving system default."; return 0; }
  log_info "Setting keyboard layout to $LOCALE_KEYBOARD_LAYOUT."
  if sudo "${_RC_ENV[@]}" "$RASPI_CONFIG_BIN" nonint do_configure_keyboard "$LOCALE_KEYBOARD_LAYOUT"; then
    status_set "$STATUS_FILE" "LOCALE_FW_KEYBOARD_LAYOUT_APPLIED" "$LOCALE_KEYBOARD_LAYOUT"
    log_ok "Keyboard layout set to $LOCALE_KEYBOARD_LAYOUT."
  else
    log_warn "raspi-config do_configure_keyboard failed for $LOCALE_KEYBOARD_LAYOUT (rc=$?); continuing."
  fi
}

_apply_keyboard_model() {
  [[ -z $LOCALE_KEYBOARD_MODEL ]] && { log_info "LOCALE_KEYBOARD_MODEL blank; preserving system default."; return 0; }
  if [[ ! -f $KEYBOARD_FILE ]]; then
    log_warn "$KEYBOARD_FILE not found; cannot set keyboard model."
    return 0
  fi
  local current
  current=$(grep '^XKBMODEL=' "$KEYBOARD_FILE" 2>/dev/null | sed 's/XKBMODEL="\(.*\)"/\1/')
  if [[ "$current" == "$LOCALE_KEYBOARD_MODEL" ]]; then
    log_info "Keyboard model already $LOCALE_KEYBOARD_MODEL; skipping."
    status_set "$STATUS_FILE" "LOCALE_FW_KEYBOARD_MODEL_APPLIED" "$LOCALE_KEYBOARD_MODEL"
    return 0
  fi
  log_info "Setting keyboard model from '$current' to $LOCALE_KEYBOARD_MODEL."
  if sudo sed -i "s/^XKBMODEL=.*/XKBMODEL=\"$LOCALE_KEYBOARD_MODEL\"/" "$KEYBOARD_FILE"; then
    # Apply to the physical console without waiting for a reboot. SSH sessions
    # are unaffected — SSH uses the client's keyboard layout, not the Pi's —
    # so this is purely for tty1/local-console use. Best-effort: setupcon
    # missing or failing isn't a hard error, the change takes effect on the
    # next reboot regardless.
    sudo setupcon --save 2>/dev/null || true
    status_set "$STATUS_FILE" "LOCALE_FW_KEYBOARD_MODEL_APPLIED" "$LOCALE_KEYBOARD_MODEL"
    log_ok "Keyboard model set to $LOCALE_KEYBOARD_MODEL."
  else
    log_warn "Failed to update $KEYBOARD_FILE for keyboard model."
  fi
}

_apply_wifi_country() {
  [[ -z $LOCALE_WIFI_COUNTRY ]] && { log_info "LOCALE_WIFI_COUNTRY blank; preserving system default."; return 0; }
  log_info "Setting WiFi country to $LOCALE_WIFI_COUNTRY."
  if sudo "${_RC_ENV[@]}" "$RASPI_CONFIG_BIN" nonint do_wifi_country "$LOCALE_WIFI_COUNTRY"; then
    status_set "$STATUS_FILE" "LOCALE_FW_WIFI_COUNTRY_APPLIED" "$LOCALE_WIFI_COUNTRY"
    log_ok "WiFi country set to $LOCALE_WIFI_COUNTRY."
  else
    log_warn "raspi-config do_wifi_country failed for $LOCALE_WIFI_COUNTRY (rc=$?); continuing."
  fi
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "Localizations already applied at recorded version. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  if [[ ! -x "$RASPI_CONFIG_BIN" ]]; then
    log_info "Ensuring raspi-config is installed."
    if ! apt_ensure_installed raspi-config; then
      status_mark_failed "$II_ID" "could not install raspi-config"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install raspi-config (required for locale)."
      return 1
    fi
  fi

  _apply_locale
  _apply_timezone
  _apply_keyboard_layout
  _apply_keyboard_model
  _apply_wifi_country

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "Localizations applied."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully applied localizations."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Localizations already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Localizations already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for locale; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # Localization changes don't capture pre-state — we don't snapshot the
  # previous /etc/default/locale, /etc/timezone, etc. Roll-back would mean
  # picking arbitrary "default" values, which is worse than no-op. Mark
  # as uninstalled in the status ledger and leave the actual settings in
  # place; the user can re-run raspi-config to change them.
  log_warn "Localization changes are not reversible by installicious. Use raspi-config (or edit /etc/default/{locale,keyboard}) to roll back manually."
  status_mark_uninstalled "$II_ID"
  echo -e "[  \e[0;32mOK\e[0m  ] Localization status cleared (settings unchanged; reset manually if needed)."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
