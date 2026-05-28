#!/bin/bash

# Module:      RTC chip-child: DS3231 (I²C, temp-compensated)
# Description: Wires the dtoverlay=i2c-rtc,ds3231 line into
#              /boot/firmware/config.txt and delegates the install
#              state machine to lib/rtc.sh.
#
#              DS3231 is the most common Pi RTC by a wide margin —
#              HiLetgo modules, DS3231-AT24C32 combo boards, etc.
#              Hence II_DEFAULT_SELECTED="on" and II_RADIO_ORDER="1".

# === II_MANIFEST_BEGIN ===
II_ID="rtc-ds3231"
II_TITLE="DS3231 — temp-compensated, most common"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="i2c-tools"
II_OPTIONAL_GROUP="rtc"
II_DEFAULT_SELECTED="on"
II_REQUIRES_REBOOT="always"
II_RADIO_ORDER="1"
II_EDITABLE_CONFIG="RTC_I2C_BUS RTC_PURGE_FAKE_HWCLOCK"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
[[ -f config/rtc.config ]] && source config/rtc.config
source lib/log.sh
source lib/status.sh
source lib/reboot.sh
source lib/boot-config.sh
source lib/rtc.sh

RTC_CHIP="ds3231"
RTC_BUS="i2c"
RTC_OVERLAY_NAME="ds3231"

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
