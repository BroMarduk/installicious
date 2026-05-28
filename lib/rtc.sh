#!/bin/bash

# lib/rtc.sh — shared RTC install/uninstall/verify state machine.
#
# Each chip-child (features/feature-rtc-<chip>.sh) sets these vars and
# delegates to one of the three functions below:
#
#   RTC_CHIP            short chip name (e.g. "ds3231")
#   RTC_BUS             "i2c" | "spi" | "pi5-builtin"
#   RTC_OVERLAY_NAME    overlay suffix used in dtoverlay= line; empty
#                       for pi5-builtin (no overlay needed)
#
# Reads config knobs (set by the menu / config files):
#   RTC_PURGE_FAKE_HWCLOCK  "yes" | "no" (default "yes")
#   RTC_I2C_BUS             default "1"
#   RTC_SPI_CS_PIN          default "0"
#   RTC_SKIP_BOOT_CONFIG_WRITE   test-only env: skips actual config.txt writes.
#   RTC_SKIP_HWCLOCK             test-only env: skips hwclock invocations.
#
# State persisted at $PATH_STATE/rtc.state (sourced as shell file):
#   RTC_CHIP, RTC_BUS_TYPE, RTC_OVERLAY_NAME, RTC_I2C_BUS,
#   RTC_SPI_CS_PIN, RTC_PHASE ("staged" | "verified"),
#   RTC_PURGED_FAKE_HWCLOCK, RTC_COMMENTED_FOREIGN_OVERLAY.

source config/installicious.config 2>/dev/null || true
source lib/log.sh 2>/dev/null || true
source lib/status.sh 2>/dev/null || true
source lib/reboot.sh 2>/dev/null || true
source lib/boot-config.sh 2>/dev/null || true

_RTC_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/rtc.state"

# _rtc_state_write <KEY=VALUE> ...
# Atomic write mirroring lib/state.sh::_state_write_pairs (but local
# to keep lib/rtc.sh self-contained for tests that may not source state.sh).
_rtc_state_write() {
  local dir tmp
  dir=$(dirname "$_RTC_STATE_FILE")
  mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir"
  tmp=$(mktemp "${_RTC_STATE_FILE}.XXXXXX" 2>/dev/null) \
    || tmp=$(sudo mktemp "${_RTC_STATE_FILE}.XXXXXX")
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    printf '%s="%s"\n' "$key" "$value"
  done > "$tmp" 2>/dev/null || {
    for pair in "$@"; do
      key="${pair%%=*}"
      value="${pair#*=}"
      printf '%s="%s"\n' "$key" "$value"
    done | sudo tee "$tmp" > /dev/null
  }
  mv -f "$tmp" "$_RTC_STATE_FILE" 2>/dev/null \
    || sudo mv -f "$tmp" "$_RTC_STATE_FILE"
}

# _rtc_state_load — source the state file (if present). Quietly returns
# rc=1 if no state file.
_rtc_state_load() {
  [[ -f $_RTC_STATE_FILE ]] || return 1
  # shellcheck disable=SC1090
  source "$_RTC_STATE_FILE"
}

# _rtc_apt_purge_fake_hwclock — apt-purge fake-hwclock if installed.
# Records the action so --uninstall can reinstall.
_rtc_apt_purge_fake_hwclock() {
  if dpkg-query -W -f='${Status}' fake-hwclock 2>/dev/null | grep -q "ok installed"; then
    log_info "Purging fake-hwclock (RTC will take over)."
    DEBIAN_FRONTEND=noninteractive apt-get -y purge fake-hwclock \
      || sudo DEBIAN_FRONTEND=noninteractive apt-get -y purge fake-hwclock
    echo "yes"
  else
    log_info "fake-hwclock not installed; nothing to purge."
    echo "no"
  fi
}

# _rtc_wait_ntp_synced [<timeout_seconds>] — poll timedatectl until
# NTPSynchronized=yes OR timeout. Returns rc=0 on sync, rc=1 on timeout.
_rtc_wait_ntp_synced() {
  local timeout="${1:-60}" elapsed=0
  while (( elapsed < timeout )); do
    if timedatectl show -p NTPSynchronized 2>/dev/null | grep -q "NTPSynchronized=yes"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# _rtc_overlay_family <bus> — echoes the overlay family prefix:
#   i2c → i2c-rtc
#   spi → spi-rtc
#   pi5-builtin → (empty)
_rtc_overlay_family() {
  case "$1" in
    i2c) echo i2c-rtc ;;
    spi) echo spi-rtc ;;
    *)   echo "" ;;
  esac
}

# _rtc_detect_foreign_overlay
# Scans config.txt for an existing dtoverlay=i2c-rtc, or spi-rtc, line
# OUTSIDE our installicious:rtc fenced block. Echoes the offending
# line if found, empty otherwise. Read-only.
_rtc_detect_foreign_overlay() {
  local cfg
  cfg=$(boot_config_path)
  [[ -f $cfg ]] || return 0
  # Skip lines inside our own fenced block. Use awk to track in/out.
  awk '
    /^# === installicious:rtc begin ===$/ { in_block=1; next }
    /^# === installicious:rtc end ===$/   { in_block=0; next }
    in_block { next }
    /^[[:space:]]*dtoverlay=(i2c|spi)-rtc,/ { print; exit 0 }
  ' "$cfg"
}

# _rtc_comment_foreign_overlay <line>
# Prepend # to the matching line in config.txt. Idempotent (no-op if
# already commented).
_rtc_comment_foreign_overlay() {
  local line cfg new
  line="$1"
  cfg=$(boot_config_path)
  new=$(awk -v needle="$line" '
    $0 == needle { print "#" $0; next }
    { print }
  ' "$cfg")
  _boot_config_write_atomic "$cfg" <<< "$new"
}

# _rtc_uncomment_foreign_overlay <original_line>
# Find a line that is `#<original_line>` and strip the leading #.
_rtc_uncomment_foreign_overlay() {
  local original cfg new commented
  original="$1"
  cfg=$(boot_config_path)
  commented="#${original}"
  new=$(awk -v needle="$commented" -v repl="$original" '
    $0 == needle { print repl; next }
    { print }
  ' "$cfg")
  _boot_config_write_atomic "$cfg" <<< "$new"
}

# rtc_install <chip> <bus_type> [<bus_extra>]
# Two-phase install. First call: stages config.txt + reboot. Second
# call (post-reboot, RTC_PHASE=staged): verifies hardware + sets time.
rtc_install() {
  local chip="$1" bus="$2"
  local bus_extra="${3:-}"

  # State-driven branching.
  if _rtc_state_load && [[ "${RTC_PHASE:-}" == "verified" ]]; then
    if rtc_verify "$chip" >/dev/null 2>&1; then
      log_info "RTC already verified for chip=$chip; hardware confirmed."
    else
      log_warn "RTC marked verified but verify checks failed; leaving state as-is (re-run 'installicious --verify rtc-$chip' for details)."
    fi
    return 0
  fi

  if _rtc_state_load && [[ "${RTC_PHASE:-}" == "staged" ]]; then
    _rtc_install_post_reboot "$chip" "$bus"
    return $?
  fi

  # First cycle.
  _rtc_install_first_cycle "$chip" "$bus"
}

# _rtc_install_first_cycle <chip> <bus>
_rtc_install_first_cycle() {
  local chip="$1" bus="$2"
  local purged="no"
  local overlay_family overlay_line
  local commented_foreign=""
  overlay_family=$(_rtc_overlay_family "$bus")

  log_info "RTC install (first cycle): chip=$chip bus=$bus."

  if [[ ${RTC_SKIP_BOOT_CONFIG_WRITE:-} != "true" ]]; then
    # Pre-install gates — config.txt presence.
    local cfg
    cfg=$(boot_config_path)
    if [[ ! -f $cfg ]]; then
      log_fail "Boot config not found at $cfg; cannot configure RTC."
      return 1
    fi

    boot_config_backup_once

    # Pre-install gate: detect a hand-configured RTC overlay outside
    # our fenced block. If found, prompt (interactive) or auto-comment
    # (RTC_NONINTERACTIVE=true, e.g. resume / test harness).
    local foreign
    foreign=$(_rtc_detect_foreign_overlay)
    if [[ -n $foreign ]]; then
      local proceed=0
      if [[ ${RTC_NONINTERACTIVE:-false} == "true" ]]; then
        proceed=1
        log_info "Foreign RTC overlay detected; auto-commenting (non-interactive mode): $foreign"
      else
        if whiptail --title "RTC: existing overlay detected" \
          --yes-button "Continue" --no-button "Cancel" \
          --yesno "Existing RTC overlay detected:\n\n  $foreign\n\nContinue and let installicious own RTC management? The existing line will be commented out (and restored at --uninstall)." 16 78 \
          2>/dev/null; then
          proceed=1
        fi
      fi
      if [[ $proceed -ne 1 ]]; then
        log_fail "Foreign RTC overlay detected; user declined. Aborting."
        return 1
      fi
      _rtc_comment_foreign_overlay "$foreign"
      commented_foreign="$foreign"
    fi

    # Bus enable.
    case "$bus" in
      i2c) boot_config_dtparam_set i2c_arm on ;;
      spi) boot_config_dtparam_set spi on ;;
      pi5-builtin) : ;;  # internal bus is permanent.
    esac

    # Overlay.
    if [[ -n $overlay_family ]]; then
      overlay_line="dtoverlay=${overlay_family},${chip}"
      boot_config_overlay_add rtc "$overlay_line"
    fi
  fi

  # Optional: purge fake-hwclock.
  if [[ "${RTC_PURGE_FAKE_HWCLOCK:-yes}" == "yes" ]]; then
    purged=$(_rtc_apt_purge_fake_hwclock | tail -1)
  fi

  # Persist state.
  _rtc_state_write \
    "RTC_CHIP=$chip" \
    "RTC_BUS_TYPE=$bus" \
    "RTC_OVERLAY_NAME=${overlay_family:+$chip}" \
    "RTC_I2C_BUS=${RTC_I2C_BUS:-1}" \
    "RTC_SPI_CS_PIN=${RTC_SPI_CS_PIN:-0}" \
    "RTC_PHASE=staged" \
    "RTC_PURGED_FAKE_HWCLOCK=$purged" \
    "RTC_COMMENTED_FOREIGN_OVERLAY=$commented_foreign"

  log_info "RTC config staged; requesting reboot to load the overlay."
  declare -F request_reboot >/dev/null \
    && request_reboot "RTC overlay requires reboot to load" "rtc-$chip"
  return "${EXIT_REBOOT:-255}"
}

# _rtc_install_post_reboot <chip> <bus>
_rtc_install_post_reboot() {
  local chip="$1" bus="$2"
  log_info "RTC post-reboot verify: chip=$chip bus=$bus."

  # Hardware probe.
  local rtc_name=""
  local sysfs_dir="${RTC_SYS_RTC0_OVERRIDE:-/sys/class/rtc/rtc0}"
  if [[ ${RTC_SKIP_HWCLOCK:-} != "true" ]]; then
    if [[ ! -e $sysfs_dir/name ]]; then
      log_fail "RTC device $sysfs_dir not present after reboot. Check wiring/pull-ups; state stays 'staged'."
      return 1
    fi
    rtc_name=$(cat "$sysfs_dir/name" 2>/dev/null)
    # Expected names: "rtc-<chip>" for I²C; "rtc-pcf85063" for Pi 5.
    local expected="rtc-$chip"
    [[ "$bus" == "pi5-builtin" ]] && expected="rtc-pcf85063"
    if [[ "$rtc_name" != *"$expected"* ]]; then
      log_fail "RTC chip name mismatch: expected '$expected', got '$rtc_name'. State stays 'staged'."
      return 1
    fi
  fi

  # Wait for NTP convergence then push system → RTC. The NTP check is
  # gated independently from RTC_SKIP_HWCLOCK so tests can exercise the
  # "NTP not synced → stay 'staged'" path without needing real sysfs /
  # hwclock binaries. RTC_SKIP_HWCLOCK only skips the sysfs probe above
  # and the hwclock --systohc invocation below.
  if _rtc_wait_ntp_synced 60; then
    log_info "NTP synced; pushing system time to RTC."
    if [[ ${RTC_SKIP_HWCLOCK:-} != "true" ]]; then
      hwclock --systohc 2>/dev/null || sudo hwclock --systohc \
        || log_warn "hwclock --systohc returned non-zero; check manually."
    fi
  else
    log_warn "NTP did not converge in 60s; skipping hwclock --systohc. Re-run later when network is up."
    return 0
  fi

  _rtc_state_write \
    "RTC_CHIP=${RTC_CHIP:-$chip}" \
    "RTC_BUS_TYPE=${RTC_BUS_TYPE:-$bus}" \
    "RTC_OVERLAY_NAME=${RTC_OVERLAY_NAME:-}" \
    "RTC_I2C_BUS=${RTC_I2C_BUS:-1}" \
    "RTC_SPI_CS_PIN=${RTC_SPI_CS_PIN:-0}" \
    "RTC_PHASE=verified" \
    "RTC_PURGED_FAKE_HWCLOCK=${RTC_PURGED_FAKE_HWCLOCK:-no}" \
    "RTC_COMMENTED_FOREIGN_OVERLAY=${RTC_COMMENTED_FOREIGN_OVERLAY:-}"

  log_ok "RTC verified and time synced."
  return 0
}

# rtc_uninstall <chip> <bus>
rtc_uninstall() {
  local chip="$1" bus="$2"

  if ! _rtc_state_load; then
    log_info "No RTC state file; nothing to revert."
    return 0
  fi

  # Preserve current system clock if RTC was working.
  if [[ ${RTC_SKIP_HWCLOCK:-} != "true" ]]; then
    hwclock --hctosys 2>/dev/null || sudo hwclock --hctosys 2>/dev/null || true
  fi

  # Restore fake-hwclock if we purged it.
  if [[ "${RTC_PURGED_FAKE_HWCLOCK:-}" == "yes" ]]; then
    log_info "Restoring fake-hwclock."
    DEBIAN_FRONTEND=noninteractive apt-get -y install fake-hwclock \
      || sudo DEBIAN_FRONTEND=noninteractive apt-get -y install fake-hwclock
    systemctl enable --now fake-hwclock 2>/dev/null \
      || sudo systemctl enable --now fake-hwclock 2>/dev/null \
      || true
  fi

  if [[ ${RTC_SKIP_BOOT_CONFIG_WRITE:-} != "true" ]]; then
    boot_config_overlay_remove rtc
    if [[ -n ${RTC_COMMENTED_FOREIGN_OVERLAY:-} ]]; then
      _rtc_uncomment_foreign_overlay "$RTC_COMMENTED_FOREIGN_OVERLAY"
      log_info "Restored foreign RTC overlay: $RTC_COMMENTED_FOREIGN_OVERLAY"
    fi
    # Leave dtparam=i2c_arm=on alone by default (shared bus).
    if [[ "${RTC_UNINSTALL_DISABLE_I2C_BUS:-no}" == "yes" && "$bus" == "i2c" ]]; then
      boot_config_dtparam_unset i2c_arm
    fi
  fi

  rm -f "$_RTC_STATE_FILE" 2>/dev/null || sudo rm -f "$_RTC_STATE_FILE"

  log_info "RTC removed; requesting reboot to unload overlay."
  declare -F request_reboot >/dev/null \
    && request_reboot "RTC overlay removed; reboot to apply" "rtc-$chip"
  return 0
}

# rtc_verify <chip>
rtc_verify() {
  local chip="$1"
  local fails=0
  local sysfs_dir="${RTC_SYS_RTC0_OVERRIDE:-/sys/class/rtc/rtc0}"

  if [[ ! -e $sysfs_dir ]]; then
    log_warn "verify: $sysfs_dir not present."
    fails=$((fails + 1))
  fi

  if [[ -e $sysfs_dir/name ]]; then
    local n
    n=$(cat "$sysfs_dir/name" 2>/dev/null)
    local expected="rtc-$chip"
    if _rtc_state_load && [[ "${RTC_BUS_TYPE:-}" == "pi5-builtin" ]]; then
      expected="rtc-pcf85063"
    fi
    if [[ "$n" != *"$expected"* ]]; then
      log_warn "verify: chip mismatch (got '$n', expected '$expected')."
      fails=$((fails + 1))
    fi
  fi

  local hw_output hw_year
  if ! hw_output=$(hwclock -r 2>/dev/null) \
     && ! hw_output=$(sudo hwclock -r 2>/dev/null); then
    log_warn "verify: hwclock -r failed (RTC not responding)."
    fails=$((fails + 1))
  else
    # hwclock outputs something like "2026-05-28 12:34:56.789012+00:00" —
    # year is the first 4 digits.
    hw_year="${hw_output:0:4}"
    if ! [[ $hw_year =~ ^[0-9]{4}$ ]] || (( hw_year < 2026 )); then
      log_warn "verify: hwclock time looks unset/stale (year=$hw_year, want ≥ 2026)."
      fails=$((fails + 1))
    fi
  fi

  if [[ -f $(boot_config_path) ]]; then
    if ! boot_config_overlay_has rtc \
         && [[ "${RTC_BUS_TYPE:-}" != "pi5-builtin" ]]; then
      log_warn "verify: installicious:rtc block missing from $(boot_config_path)."
      fails=$((fails + 1))
    fi
  fi

  return $fails
}
