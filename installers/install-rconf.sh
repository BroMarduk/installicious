#!/bin/bash

# Module:      Raspberry Pi Configuration
# Description: Applies a curated subset of `raspi-config nonint` settings
#              suitable for headless Lite installs that have already been
#              partially configured by the Pi Imager wizard. Picks up
#              defaults from config/rconf.config; users override individual
#              values via the menu config editor.
#
#              Per-option applicability (Pi model, OS version, Lite vs
#              Full) is enforced by installers/install-rconf.choices.sh:
#              a key whose _applies_/_choices_ helper rejects this system
#              is hidden from the menu AND its config value is silently
#              ignored at install time. So setting RCONF_USB_CURRENT_UNLIMITED
#              on a Pi 4 is a no-op (it's a Pi 5 setting).
#
#              Imager-handled inputs (timezone, Wi-Fi country, hostname,
#              SSH enable, initial user/password, RPi Connect) are NOT
#              applied here — set them at flash time via the Pi Imager.
#
#              Bump II_VERSION to force a re-run.

# === II_MANIFEST_BEGIN ===
II_ID="rconf"
II_TITLE="Raspberry Pi Configuration"
II_CATEGORY="option"
II_VERSION="2"
II_DEPS=""
II_REQUIRES_REBOOT="conditional"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="RCONF_LOCALE RCONF_KEYBOARD_MODEL RCONF_BOOT_TARGET RCONF_BOOT_AUTOLOGIN RCONF_OVERLAYFS RCONF_BOOT_ORDER RCONF_BOOTLOADER_VERSION RCONF_USB_CURRENT_UNLIMITED"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/menu.sh
source lib/apt.sh
source lib/reboot.sh

EXIT_REBOOT=255

# Pull in OS / Pi-model detection so the choices/applies helpers can gate
# correctly. installicious.sh writes this on every run.
[[ -f "$PATH_STATUS/os.status" ]] && source "$PATH_STATUS/os.status"

# Source the choices file so menu_key_applicable can route through
# _applies_<KEY> / _choices_<KEY> for each editable key. Side-effect-free.
CHOICES_FILE="${PATH_INSTALLERS:-installers}/install-rconf.choices.sh"
[[ -f $CHOICES_FILE ]] && source "$CHOICES_FILE"

# Baseline config + user edits. menu-config.sh wins, per the established
# layering rule.
FILE_CONFIG_RCONF="${PATH_CONFIG:-config}/rconf.config"
[[ -f $FILE_CONFIG_RCONF ]] && source "$FILE_CONFIG_RCONF"
state_apply_menu_overrides

# Defaults guard against an empty config file.
RCONF_LOCALE="${RCONF_LOCALE:-en_US.UTF-8}"
RCONF_KEYBOARD_MODEL="${RCONF_KEYBOARD_MODEL:-pc105}"
RCONF_BOOT_TARGET="${RCONF_BOOT_TARGET:-console}"
RCONF_BOOT_AUTOLOGIN="${RCONF_BOOT_AUTOLOGIN:-true}"
RCONF_BLANKING="${RCONF_BLANKING:-false}"
RCONF_INTERFACE_SPI="${RCONF_INTERFACE_SPI:-false}"
RCONF_INTERFACE_I2C="${RCONF_INTERFACE_I2C:-false}"
RCONF_INTERFACE_ONEWIRE="${RCONF_INTERFACE_ONEWIRE:-false}"
RCONF_INTERFACE_SERIAL_CONSOLE="${RCONF_INTERFACE_SERIAL_CONSOLE:-false}"
RCONF_INTERFACE_SERIAL_HW_UART="${RCONF_INTERFACE_SERIAL_HW_UART:-false}"
RCONF_OVERLAYFS="${RCONF_OVERLAYFS:-false}"
RCONF_BOOT_ORDER="${RCONF_BOOT_ORDER:-0xf41}"
RCONF_BOOTLOADER_VERSION="${RCONF_BOOTLOADER_VERSION:-default}"
RCONF_OVERCLOCK="${RCONF_OVERCLOCK:-default}"
RCONF_FAN_ENABLE="${RCONF_FAN_ENABLE:-false}"
RCONF_FAN_GPIO="${RCONF_FAN_GPIO:-14}"
RCONF_FAN_TEMP="${RCONF_FAN_TEMP:-80}"
RCONF_POWEROFF_ON_HALT="${RCONF_POWEROFF_ON_HALT:-true}"
RCONF_USB_CURRENT_UNLIMITED="${RCONF_USB_CURRENT_UNLIMITED:-false}"

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

# raspi-config presence — install-rconf is a thin wrapper around it.
if declare -F apt_ensure_installed >/dev/null; then
  apt_ensure_installed raspi-config \
    || { log_fail "Could not ensure raspi-config is installed."; status_mark_failed "$II_ID" "raspi-config install failed"; exit 1; }
fi
if [[ ! -x /usr/bin/raspi-config ]]; then
  log_fail "raspi-config not found at /usr/bin/raspi-config — refusing to proceed."
  status_mark_failed "$II_ID" "raspi-config missing"
  exit 1
fi

# raspi-config nonint command prefix.
RC="sudo raspi-config nonint"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _bool_to_rc_arg <bool> — translate a yes/no config value into the upstream
# raspi-config "0=enable, 1=disable" convention.
_bool_to_rc_arg() {
  case "${1,,}" in
    true|yes|1|on|enable|enabled) echo 0 ;;
    *)                            echo 1 ;;
  esac
}

# _skip_if_not_applicable <key> — log + return rc=1 when a key shouldn't
# apply on this system (Pi model, OS version, Lite vs Full). Used to gate
# every apply_* function so config values for inapplicable keys are
# silently ignored.
_skip_if_not_applicable() {
  local key="$1"
  if menu_key_applicable "$key"; then
    return 0
  fi
  log_info "Skipping $key — not applicable on Pi ${II_MODEL_NUM:-?} / ${II_CODENAME:-?} / lite=${II_IS_LITE:-?}."
  return 1
}

_run_rc() {
  if "$@"; then
    return 0
  fi
  log_warn "raspi-config returned non-zero: $*"
  return 1
}

# ---------------------------------------------------------------------------
# Per-option apply functions
# ---------------------------------------------------------------------------

apply_locale() {
  [[ -n $RCONF_LOCALE ]] || return 0
  log_info "Setting locale to $RCONF_LOCALE."
  _run_rc $RC do_change_locale "$RCONF_LOCALE"
}

apply_keyboard_model() {
  _skip_if_not_applicable RCONF_KEYBOARD_MODEL || return 0
  [[ -n $RCONF_KEYBOARD_MODEL ]] || return 0
  local kbd="/etc/default/keyboard"
  if [[ ! -f $kbd ]]; then
    log_warn "$kbd not present — skipping keyboard model change."
    return 0
  fi
  # raspi-config's nonint do_configure_keyboard sets XKBLAYOUT only (the
  # country code). It has no nonint helper for XKBMODEL, so we edit the
  # file directly and then dpkg-reconfigure to apply.
  log_info "Setting XKBMODEL to $RCONF_KEYBOARD_MODEL in $kbd."
  if grep -qE '^XKBMODEL=' "$kbd"; then
    sudo sed -i -E "s|^XKBMODEL=.*|XKBMODEL=\"${RCONF_KEYBOARD_MODEL}\"|" "$kbd" \
      || { log_warn "Failed to update XKBMODEL in $kbd."; return 1; }
  else
    echo "XKBMODEL=\"${RCONF_KEYBOARD_MODEL}\"" | sudo tee -a "$kbd" >/dev/null
  fi
  sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive keyboard-configuration \
    || log_warn "dpkg-reconfigure keyboard-configuration returned non-zero."
}

apply_boot_target() {
  _skip_if_not_applicable RCONF_BOOT_TARGET || return 0
  case "${RCONF_BOOT_TARGET,,}" in
    console) log_info "Boot target: console.";  _run_rc $RC do_boot_target 1 ;;
    desktop) log_info "Boot target: desktop.";  _run_rc $RC do_boot_target 0 ;;
    *)       log_warn "Unknown RCONF_BOOT_TARGET '$RCONF_BOOT_TARGET'." ;;
  esac
}

apply_boot_autologin() {
  _skip_if_not_applicable RCONF_BOOT_AUTOLOGIN || return 0
  log_info "Auto-login: $RCONF_BOOT_AUTOLOGIN."
  _run_rc $RC do_autologin "$(_bool_to_rc_arg "$RCONF_BOOT_AUTOLOGIN")"
}

apply_blanking() {
  _skip_if_not_applicable RCONF_BLANKING || return 0
  # raspi-config: do_blanking 0 = disable blanking, 1 = enable. Our config
  # uses true="screen blanks" / false="screen stays on" — pass through inverted.
  case "${RCONF_BLANKING,,}" in
    true|yes|1) log_info "Blanking: enabled.";  _run_rc $RC do_blanking 1 ;;
    *)          log_info "Blanking: disabled."; _run_rc $RC do_blanking 0 ;;
  esac
}

# apply_interface <RCONF_KEY> <do_func>
apply_interface() {
  local key="$1" do_func="$2"
  _skip_if_not_applicable "$key" || return 0
  local val="${!key}"
  log_info "Interface ${do_func#do_}: $val."
  _run_rc $RC "$do_func" "$(_bool_to_rc_arg "$val")"
}

apply_overlayfs() {
  _skip_if_not_applicable RCONF_OVERLAYFS || return 0
  log_info "Overlay filesystem: $RCONF_OVERLAYFS."
  _run_rc $RC do_overlayfs "$(_bool_to_rc_arg "$RCONF_OVERLAYFS")"
}

apply_boot_order() {
  _skip_if_not_applicable RCONF_BOOT_ORDER || return 0
  log_info "Boot order: $RCONF_BOOT_ORDER."
  _run_rc $RC do_boot_order "$RCONF_BOOT_ORDER"
}

apply_bootloader_version() {
  _skip_if_not_applicable RCONF_BOOTLOADER_VERSION || return 0
  case "${RCONF_BOOTLOADER_VERSION,,}" in
    latest)  log_info "Bootloader: latest (e1)."; _run_rc $RC do_boot_rom e1 ;;
    default) log_info "Bootloader: default (e2)."; _run_rc $RC do_boot_rom e2 ;;
    *)       log_warn "Unknown RCONF_BOOTLOADER_VERSION '$RCONF_BOOTLOADER_VERSION'." ;;
  esac
}

apply_overclock() {
  _skip_if_not_applicable RCONF_OVERCLOCK || return 0
  case "${RCONF_OVERCLOCK,,}" in
    default|none) log_info "Overclock: none.";   _run_rc $RC do_overclock None ;;
    modest)       log_info "Overclock: Modest."; _run_rc $RC do_overclock Modest ;;
    medium)       log_info "Overclock: Medium."; _run_rc $RC do_overclock Medium ;;
    high)         log_info "Overclock: High.";   _run_rc $RC do_overclock High ;;
    turbo)        log_info "Overclock: Turbo.";  _run_rc $RC do_overclock Turbo ;;
    *)            log_warn "Unknown RCONF_OVERCLOCK '$RCONF_OVERCLOCK'." ;;
  esac
}

apply_fan() {
  _skip_if_not_applicable RCONF_FAN_ENABLE || return 0
  case "${RCONF_FAN_ENABLE,,}" in
    true|yes|1)
      log_info "Fan: enable on GPIO $RCONF_FAN_GPIO at $RCONF_FAN_TEMP°C."
      _run_rc $RC do_fan 0 "$RCONF_FAN_GPIO" "$RCONF_FAN_TEMP"
      ;;
    *)
      log_info "Fan: disable raspi-config-managed control."
      _run_rc $RC do_fan 1
      ;;
  esac
}

apply_power_off_on_halt() {
  _skip_if_not_applicable RCONF_POWEROFF_ON_HALT || return 0
  log_info "Power-off on halt: $RCONF_POWEROFF_ON_HALT."
  _run_rc $RC do_power_off_on_halt "$(_bool_to_rc_arg "$RCONF_POWEROFF_ON_HALT")"
}

apply_usb_current() {
  _skip_if_not_applicable RCONF_USB_CURRENT_UNLIMITED || return 0
  log_info "USB current unlimited: $RCONF_USB_CURRENT_UNLIMITED."
  _run_rc $RC do_usb_current "$(_bool_to_rc_arg "$RCONF_USB_CURRENT_UNLIMITED")"
}

# ---------------------------------------------------------------------------
# do_install / do_uninstall
# ---------------------------------------------------------------------------

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_RCONF"; then
    log_info "rconf already applied at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  apply_locale
  apply_keyboard_model
  apply_boot_target
  apply_boot_autologin
  apply_blanking
  apply_interface RCONF_INTERFACE_SPI            do_spi
  apply_interface RCONF_INTERFACE_I2C            do_i2c
  apply_interface RCONF_INTERFACE_ONEWIRE        do_onewire
  apply_interface RCONF_INTERFACE_SERIAL_CONSOLE do_serial_cons
  apply_interface RCONF_INTERFACE_SERIAL_HW_UART do_serial_hw
  apply_overlayfs
  apply_boot_order
  apply_bootloader_version
  apply_overclock
  apply_fan
  apply_power_off_on_halt
  apply_usb_current

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_RCONF"
  log_ok "rconf settings applied."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully applied raspi-config settings."

  # Defer the reboot decision to upstream raspi-config: it touches
  # /var/run/reboot-required when its operations need a reboot. lib/reboot.sh
  # persists scheduler state and triggers the systemd-managed resume.
  if [[ -e /var/run/reboot-required ]]; then
    if declare -F request_reboot >/dev/null; then
      log_info "raspi-config requested a reboot — handing off to systemd-resume."
      request_reboot "rconf settings change requires reboot to take effect" "rconf"
      return $EXIT_REBOOT
    else
      log_warn "Reboot required but lib/reboot.sh not loaded — please reboot manually."
    fi
  fi
  return 0
}

do_uninstall() {
  log_warn "rconf is not reversible (raspi-config writes spread across config.txt, EEPROM, locale, dpkg-reconfigure). Marking uninstalled."
  status_mark_uninstalled "$II_ID"
  echo -e "[  \e[0;32mOK\e[0m  ] Marked rconf as uninstalled (no rollback performed)."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
