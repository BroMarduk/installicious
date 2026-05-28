#!/bin/bash

# Module:      RTC chip-child: ABx80x (I²C, Abracon)
# Description: Wires the dtoverlay=i2c-rtc,abx80x line into
#              /boot/firmware/config.txt and delegates the install
#              state machine to lib/rtc.sh.
#
#              ABx80x is Abracon's RTC family (AB0801, AB0803,
#              AB1801, AB1803, etc.) — used in industrial and
#              medical equipment.

# === II_MANIFEST_BEGIN ===
II_ID="rtc-abx80x"
II_TITLE="ABx80x — Abracon"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="i2c-tools"
II_DEFAULT_SELECTED="off"
II_REQUIRES_REBOOT="always"
II_RADIO_ORDER="11"
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

RTC_CHIP="abx80x"
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
