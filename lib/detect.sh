#!/bin/bash

# lib/detect.sh — Raspberry Pi hardware detection helpers.
#
# Sources the canonical `Model:` line from /proc/cpuinfo, the same approach
# upstream raspi-config uses (is_pifour / is_pifive / is_pizero). This is
# more robust than parsing the revision-code regex, which has to be
# updated for every new hardware revision.
#
# Public functions:
#   detect_pi_model [<cpuinfo_path>]   - echoes 0..5 (or 99 if unknown)
#   detect_pi_is_zero [<cpuinfo_path>] - rc=0 if any Pi Zero variant, else rc=1
#
# The optional <cpuinfo_path> argument lets tests inject synthetic
# cpuinfo content; production callers omit it (defaults to /proc/cpuinfo).
#
# Pi Zero family is mapped to its hardware-equivalent model number so the
# Pi-N gating in feature-rconf.choices.sh works without special-casing:
#   Pi Zero / Zero W (BCM2835, single-core ARM11) → model 0 (Pi 1 family)
#   Pi Zero 2 W      (BCM2710, quad-core A53)     → model 3 (Pi 3 family)
# Code that needs to specifically distinguish a Zero (e.g. RAM-aware
# decisions) can also check $II_IS_PIZERO from os.status.

# detect_pi_model [<cpuinfo_path>] -> echo 0..5 or 99
detect_pi_model() {
  local cpuinfo="${1:-/proc/cpuinfo}"
  [[ -f $cpuinfo ]] || { echo 99; return 0; }

  # Pi Zero 2 / 2 W shares the BCM2710 SoC with the Pi 3 — gate it the same
  # way our choices file gates Pi 3 (no boot order, no fan, no overclock).
  if grep -qE "^Model\s*:\s*Raspberry Pi Zero 2" "$cpuinfo"; then
    echo 3
    return 0
  fi
  # Original Pi Zero / Zero W — same SoC as Pi 1; treat as model 0 so the
  # `<= 2` overclock gate matches and the Pi 4/5-only stuff is hidden.
  if grep -qE "^Model\s*:\s*Raspberry Pi Zero" "$cpuinfo"; then
    echo 0
    return 0
  fi

  if grep -qE "^Model\s*:\s*Raspberry Pi 5" "$cpuinfo"; then
    echo 5
    return 0
  fi
  if grep -qE "^Model\s*:\s*Raspberry Pi (Compute Module 4|400|4 )" "$cpuinfo"; then
    echo 4
    return 0
  fi
  if grep -qE "^Model\s*:\s*Raspberry Pi (Compute Module 3|3)" "$cpuinfo"; then
    echo 3
    return 0
  fi
  if grep -qE "^Model\s*:\s*Raspberry Pi 2" "$cpuinfo"; then
    echo 2
    return 0
  fi
  # Pi 1 family — these are named by letter ("Raspberry Pi Model B Rev …",
  # "Raspberry Pi Model A+ …") rather than by number, so we match on
  # "Raspberry Pi Model " specifically. CM1 ("Raspberry Pi Compute Module")
  # also falls here.
  if grep -qE "^Model\s*:\s*Raspberry Pi (Model |Compute Module Rev)" "$cpuinfo"; then
    echo 1
    return 0
  fi
  # Anything else (future Pi 6, alien hardware, malformed cpuinfo) → unknown.
  # Fail closed so we don't silently apply the wrong gating.
  echo 99
}

# detect_pi_is_zero [<cpuinfo_path>] -> rc=0 if any Pi Zero variant, else rc=1.
detect_pi_is_zero() {
  local cpuinfo="${1:-/proc/cpuinfo}"
  [[ -f $cpuinfo ]] || return 1
  grep -qE "^Model\s*:\s*Raspberry Pi Zero" "$cpuinfo"
}

# detect_pi_has_internal_rtc — rc=0 iff this Pi has an on-board PCF85063A
# RTC. Pi 5 today; forward-compat for any future Pi whose device-tree
# exposes an internal RTC at the same node path.
#
# Two signals:
#   1. /proc/device-tree/model contains "Pi 5" (canonical).
#   2. /sys/bus/i2c/devices/1f00071000.rtc exists (Pi 5's internal I²C
#      RTC device-tree path — forward-compat hook).
#
# Either is sufficient. Side-effect-free.
detect_pi_has_internal_rtc() {
  if [[ -r /proc/device-tree/model ]]; then
    local model
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
    case "$model" in
      *"Pi 5"*) return 0 ;;
    esac
  fi
  [[ -e /sys/bus/i2c/devices/1f00071000.rtc ]] && return 0
  return 1
}
