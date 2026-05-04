#!/bin/bash

# installers/install-rconf.choices.sh — enumerated choices + applicability
# gates for install-rconf's editable config keys.
#
# Sourced by lib/menu.sh::menu_edit_config (when rconf has keys in the
# editor) and by install-rconf.sh itself at install time. Side-effect-free:
# this file MUST only define functions; no top-level work.
#
# Convention:
#   _choices_<KEY>()  echoes "value<TAB>label" lines. Empty output means the
#                     key is not applicable on this system → menu hides it
#                     AND install-rconf skips applying any config value for
#                     it. The whiptail menu picks `value` and shows `label`.
#   _applies_<KEY>()  rc=0 if applicable, rc=1 if not. Use for free-form
#                     keys that need hardware/OS gating but no enum (e.g.
#                     RCONF_FAN_GPIO is text input, Pi 4 only).
#
# Detection variables read from os.status (loaded by options.sh and by
# install-rconf.sh):
#   II_MODEL_NUM   1..5 (Pi model number; 99 if unknown)
#   II_CODENAME    "Bookworm" / "Trixie" / "Forky" / "Duke"
#   II_IS_LITE     "true" if the Pi OS Lite edition (no desktop), else "false"
#   II_OS_BITS     32 or 64

# ---------------------------------------------------------------------------
# Keyboard layout — common xkb codes. Always applicable; the Imager sets
# this to the country default but the user's actual keyboard may differ.
# ---------------------------------------------------------------------------
_choices_RCONF_KEYBOARD_LAYOUT() {
  cat <<EOF
us	United States (default)
gb	United Kingdom
de	German
fr	French
es	Spanish
it	Italian
nl	Netherlands
se	Swedish
ch	Swiss
br	Brazilian
jp	Japanese
ru	Russian
EOF
}

# ---------------------------------------------------------------------------
# Boot target — Lite installs always use console (no desktop to switch to).
# ---------------------------------------------------------------------------
_choices_RCONF_BOOT_TARGET() {
  if [[ ${II_IS_LITE:-true} == "true" ]]; then
    echo -e "console\tConsole (Lite — no desktop available)"
  else
    cat <<EOF
console	Console (text-mode login)
desktop	Desktop (graphical login)
EOF
  fi
}

# ---------------------------------------------------------------------------
# Console autologin — yes/no. Always applicable.
# ---------------------------------------------------------------------------
_choices_RCONF_BOOT_AUTOLOGIN() {
  cat <<EOF
true	Yes — auto-login as the default user
false	No — require login at the console
EOF
}

# ---------------------------------------------------------------------------
# Blanking — yes/no. Always applicable (works on console).
# ---------------------------------------------------------------------------
_choices_RCONF_BLANKING() {
  cat <<EOF
false	No — keep the screen always on (disable blanking)
true	Yes — let the screen blank after the default timeout
EOF
}

# ---------------------------------------------------------------------------
# Hardware interface toggles — yes/no. Always applicable.
# ---------------------------------------------------------------------------
_choices_RCONF_INTERFACE_SPI()             { cat <<EOF
true	Enable SPI
false	Disable SPI
EOF
}
_choices_RCONF_INTERFACE_I2C()             { cat <<EOF
true	Enable I2C
false	Disable I2C
EOF
}
_choices_RCONF_INTERFACE_ONEWIRE()         { cat <<EOF
true	Enable 1-Wire
false	Disable 1-Wire
EOF
}
_choices_RCONF_INTERFACE_SERIAL_CONSOLE()  { cat <<EOF
true	Enable serial console (login over UART)
false	Disable serial console
EOF
}
_choices_RCONF_INTERFACE_SERIAL_HW_UART()  { cat <<EOF
true	Enable hardware UART (for HATs / GPS / sensors)
false	Disable hardware UART
EOF
}

# ---------------------------------------------------------------------------
# Overlay filesystem — yes/no. Always applicable.
# ---------------------------------------------------------------------------
_choices_RCONF_OVERLAYFS() {
  cat <<EOF
false	No — writable root (default)
true	Yes — read-only root via overlayfs (reboot required)
EOF
}

# ---------------------------------------------------------------------------
# Boot order — Pi 4 / Pi 5 only. Empty on older Pis → key hidden.
# Hex codes are upstream raspi-config nomenclature; labels are human.
# ---------------------------------------------------------------------------
_choices_RCONF_BOOT_ORDER() {
  if [[ ${II_MODEL_NUM:-0} -ge 4 ]]; then
    cat <<EOF
0xf41	SD card first, then USB, then network
0xf14	USB first, then SD card, then network
0xf21	Network first, then SD card, then USB
EOF
  fi
}

# ---------------------------------------------------------------------------
# Bootloader version — Pi 4 / Pi 5 only.
# ---------------------------------------------------------------------------
_choices_RCONF_BOOTLOADER_VERSION() {
  if [[ ${II_MODEL_NUM:-0} -ge 4 ]]; then
    cat <<EOF
default	Default (Pi-stable EEPROM)
latest	Latest (newest features; may be less tested)
EOF
  fi
}

# ---------------------------------------------------------------------------
# Overclock — Pi 1/2 only on Bookworm+ (Pi 4/5 manage clocks elsewhere).
# ---------------------------------------------------------------------------
_choices_RCONF_OVERCLOCK() {
  if [[ ${II_MODEL_NUM:-0} -le 2 ]]; then
    cat <<EOF
default	Default — no overclock
modest	Modest (700 MHz → 800 MHz on Pi 1)
medium	Medium
high	High
turbo	Turbo
EOF
  fi
}

# ---------------------------------------------------------------------------
# Fan management (Pi 4 only). Enable + numeric inputs for GPIO/temp.
# ---------------------------------------------------------------------------
_choices_RCONF_FAN_ENABLE() {
  if [[ ${II_MODEL_NUM:-0} -eq 4 ]]; then
    cat <<EOF
false	No — leave fan management to firmware/external
true	Yes — manage a GPIO-driven fan via raspi-config
EOF
  fi
}
_applies_RCONF_FAN_GPIO()  { [[ ${II_MODEL_NUM:-0} -eq 4 ]]; }
_applies_RCONF_FAN_TEMP()  { [[ ${II_MODEL_NUM:-0} -eq 4 ]]; }

# ---------------------------------------------------------------------------
# Power-off on halt — Pi 4 / Pi 5 only.
# ---------------------------------------------------------------------------
_choices_RCONF_POWEROFF_ON_HALT() {
  if [[ ${II_MODEL_NUM:-0} -ge 4 ]]; then
    # NOTE: heredoc delimiter is single-quoted ('EOF') so backticks/$()/$var
    # in the labels are taken literally. An unquoted EOF would expand any
    # backticks here, and `halt` in particular is a SYSTEM-HALTING command
    # when installicious runs as root via sudo — i.e. invoking the function
    # would actually power the Pi off mid-menu. Don't change this.
    cat <<'EOF'
true	Yes - full power-off on halt / shutdown
false	No - halt only (keep the activity LED state)
EOF
  fi
}

# ---------------------------------------------------------------------------
# USB current unlimited — Pi 5 only. Lifts the 600 mA cap; needed for SSDs.
# ---------------------------------------------------------------------------
_choices_RCONF_USB_CURRENT_UNLIMITED() {
  if [[ ${II_MODEL_NUM:-0} -eq 5 ]]; then
    cat <<EOF
false	No — keep the 600 mA USB cap (default)
true	Yes — lift the cap (required for SSDs and high-power peripherals)
EOF
  fi
}
