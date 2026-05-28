#!/bin/bash

# Module:      RTC parent (grouping feature)
# Description: Pure grouping shell. Selecting "rtc" triggers a
#              single-select sub-menu (II_OPTIONAL_GROUP_MODE="exclusive")
#              where the user picks one chip. The chosen chip-child
#              feature (feature-rtc-<chip>.sh) runs the real install.
#
#              Body is a no-op apart from status bookkeeping.
#              See docs/superpowers/specs/2026-05-28-rtc-design.md.
#
# Note: parent has no II_RADIO_ORDER — that's a child-only sort hint
# consumed by menu_pick_one_optional when rendering the radio.

# === II_MANIFEST_BEGIN ===
II_ID="rtc"
II_TITLE="Real-Time Clock (RTC)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_OPTIONAL_GROUP="rtc-ds3231 rtc-pcf8523 rtc-ds1307 rtc-pcf8563 rtc-pcf2127 rtc-pi5-builtin rtc-pcf85063 rtc-mcp7940x rtc-rv3028 rtc-rv3032 rtc-abx80x rtc-rv1805 rtc-m41t62 rtc-pcf2123 rtc-max6902 rtc-ds3232-spi"
II_OPTIONAL_GROUP_MODE="exclusive"
II_RESTRICT_TO_ROLES=""
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/verify.sh

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

case "$MODE" in
  install)
    if status_should_skip "$II_ID" "$II_VERSION"; then
      log_info "RTC parent already recorded at version $II_VERSION. Skipping."
      exit 0
    fi
    status_mark_started "$II_ID"
    status_mark_complete "$II_ID" "$II_VERSION"
    log_ok "RTC parent recorded; chip-child runs the real install."
    exit 0
    ;;
  uninstall)
    status_mark_uninstalled "$II_ID"
    log_ok "RTC parent record cleared."
    exit 0
    ;;
  verify)
    declare -F verify_generic >/dev/null && exec verify_generic "$II_ID"
    exit 0
    ;;
esac
