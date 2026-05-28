#!/bin/bash

# Module:      RTC chip-child: PCF8523 (I²C, low-power)
# Description: Wires the dtoverlay=i2c-rtc,pcf8523 line into
#              /boot/firmware/config.txt and delegates the install
#              state machine to lib/rtc.sh.
#
#              PCF8523 is the chip on Adafruit's PiRTC board — a
#              popular curated pick alongside DS3231.

# === II_MANIFEST_BEGIN ===
II_ID="rtc-pcf8523"
II_TITLE="PCF8523 — Adafruit PiRTC"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="i2c-tools"
II_DEFAULT_SELECTED="off"
II_REQUIRES_REBOOT="always"
II_RADIO_ORDER="2"
II_EDITABLE_CONFIG="RTC_I2C_BUS RTC_PURGE_FAKE_HWCLOCK"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/reboot.sh
source lib/boot-config.sh
source lib/rtc.sh

[[ -f config/rtc.config ]] && source config/rtc.config
declare -F state_apply_menu_overrides >/dev/null && state_apply_menu_overrides

RTC_CHIP="pcf8523"
RTC_BUS="i2c"

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
  install)   rtc_install   "$RTC_CHIP" "$RTC_BUS" ; exit $? ;;
  uninstall) rtc_uninstall "$RTC_CHIP" "$RTC_BUS" ; exit $? ;;
  verify)    rtc_verify    "$RTC_CHIP"            ; exit $? ;;
esac
