#!/bin/bash

# Module:      RTC chip-child: Pi 5 built-in PCF85063A
# Description: The Pi 5 board has an on-die PCF85063A RTC on an internal
#              I²C bus. No overlay needed — the kernel loads the
#              rtc-pcf85063 driver automatically. This installer's
#              "config.txt" work is essentially a no-op (the boot-config
#              helper detects RTC_BUS="pi5-builtin" and skips overlay
#              writes); only fake-hwclock purge + post-reboot
#              hwclock --systohc apply.
#
#              Hidden on non-Pi-5 hardware via II_REQUIRES_INTERNAL_RTC.

# === II_MANIFEST_BEGIN ===
II_ID="rtc-pi5-builtin"
II_TITLE="Pi 5 built-in (PCF85063A)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_DEFAULT_SELECTED="off"
II_REQUIRES_REBOOT="never"
II_RADIO_ORDER="6"
II_REQUIRES_INTERNAL_RTC="==true"
II_EDITABLE_CONFIG="RTC_PURGE_FAKE_HWCLOCK"
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

RTC_CHIP="pcf85063a"
RTC_BUS="pi5-builtin"

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
