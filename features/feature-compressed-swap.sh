#!/bin/bash

# Module:      Compressed Swap (zram)
# Description: Configures /dev/zram0 as compressed-RAM swap using whichever
#              manager fits the OS:
#                - rpi-swap (preinstalled on Pi OS Trixie)
#                - zram-tools (Bookworm)
#              Disables dphys-swapfile (older SD-card swap) if present.
#              Configurable via config/zram.config.
#
#              The apt-package side (zram-tools binary + zramswap service)
#              lives in packages/package-zram-tools.sh and is pulled in by
#              the II_DEPS below — picking this feature in the menu auto-
#              schedules zram-tools first.
#
#              On install we capture pre-state — whether zram-tools was
#              installed, whether dphys-swapfile was enabled, whether
#              zramswap.service was enabled, and a backup snapshot of any
#              config files we'll replace. --uninstall reverses those,
#              restoring the system as closely as possible to its pre-
#              install state.
#
#              Reboot semantics: the installer attempts a live restart of
#              /dev/zram0, then verifies the device's actual size + algo
#              match the configured values. If the kernel refuses to reset
#              a busy device (or boot-time generator state is stale), we
#              request_reboot so the next boot picks up the config cleanly.
#
#              --uninstall                  defaults to strip-block-style revert:
#                                           remove our drop-in, restore configs
#                                           we backed up, delete configs we
#                                           created, optionally re-enable
#                                           dphys-swapfile, optionally remove
#                                           zram-tools.
#              --uninstall --restore-backup explicit alias; same behavior, since
#                                           our uninstall is fundamentally a
#                                           backup-restore.
#
# Bump II_VERSION to force a re-run on the next installicious run.
# The recorded config hash also forces a re-run if config/zram.config changes.

# === II_MANIFEST_BEGIN ===
II_ID="compressed-swap"
II_TITLE="Compressed Swap (zram)"
II_CATEGORY="feature"
II_VERSION="3"
II_DEPS="zram"
II_REQUIRES_REBOOT="conditional"
II_EDITABLE_CONFIG="ZRAM_PERCENT_OF_RAM ZRAM_COMPRESSION_ALGO ZRAM_SWAP_PRIORITY"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/reboot.sh
source lib/apt.sh
source lib/backup.sh
source lib/verify.sh

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)        MODE="install" ;;
    --uninstall)      MODE="uninstall" ;;
    --restore-backup) MODE="uninstall" ;;
    --verify)         MODE="verify" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

FILE_CONFIG_ZRAM="$PATH_CONFIG/zram.config"
[[ -f $FILE_CONFIG_ZRAM ]] && source "$FILE_CONFIG_ZRAM"
# Apply user edits from the menu_edit_config screen (Phase 2). Sourced after
# the baseline config so menu edits win for this run.
declare -F state_apply_menu_overrides >/dev/null && state_apply_menu_overrides

# Source the choices file so we can call _default_<KEY> helpers for any
# value the user left blank. The same helpers feed the menu-editor display,
# so the editor and the installer agree on smart defaults.
FILE_CHOICES_ZRAM="${PATH_FEATURES:-features}/feature-compressed-swap.choices.sh"
[[ -f $FILE_CHOICES_ZRAM ]] && source "$FILE_CHOICES_ZRAM"

# _resolve_default <var> <hardcoded_fallback>
# If <var> is empty and _default_<var> is defined, use it. Otherwise
# fall back to the hardcoded value. Lets blank-in-config "do the smart
# thing" without losing the safety net for cases where the choices
# file is somehow missing.
_resolve_default() {
  local key="$1" fallback="$2"
  local current_val="${!key}"
  if [[ -n $current_val ]]; then
    return 0
  fi
  if declare -F "_default_$key" >/dev/null; then
    printf -v "$key" '%s' "$("_default_$key")"
  else
    printf -v "$key" '%s' "$fallback"
  fi
}
_resolve_default ZRAM_PERCENT_OF_RAM   50
_resolve_default ZRAM_COMPRESSION_ALGO zstd
_resolve_default ZRAM_SWAP_PRIORITY    100
ZRAM_DISABLE_DPHYS_SWAPFILE="${ZRAM_DISABLE_DPHYS_SWAPFILE:-true}"

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

STATUS_FILE=$(status_file_for "$II_ID")

# Files we may touch. Tracked here so install (backup) and uninstall (restore)
# stay in lock-step. Overridable from the env for local round-trip tests; the
# defaults match the real system paths and are what production uses.
ZRAMSWAP_DEFAULTS="${ZRAMSWAP_DEFAULTS:-/etc/default/zramswap}"             # zram-tools path
ZRAM_GENERATOR_CONF="${ZRAM_GENERATOR_CONF:-/etc/systemd/zram-generator.conf}"  # rpi-swap path
RPI_SWAP_DROPIN="${RPI_SWAP_DROPIN:-/etc/rpi/swap.conf.d/99-installicious.conf}" # rpi-swap path (always created by us)

# Reset live zram device(s) so any new/old config can be picked up without reboot.
zram_reset_devices() {
  sudo systemctl stop dev-zram0.swap 2>/dev/null || true
  sudo systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
  local dev
  for dev in /dev/zram*; do
    [[ -b $dev ]] || continue
    if grep -q "^${dev} " /proc/swaps 2>/dev/null; then
      sudo swapoff "$dev" 2>/dev/null || true
    fi
  done
  if [[ -e /sys/block/zram0/reset ]] \
     && ! grep -qE "^/dev/zram0 " /proc/swaps /proc/mounts 2>/dev/null; then
    echo 1 | sudo tee /sys/block/zram0/reset >/dev/null 2>&1 || true
  fi
}

detect_swap_manager() {
  if dpkg -l rpi-swap 2>/dev/null | grep -q '^ii'; then
    echo "rpi-swap"
  else
    echo "zram-tools"
  fi
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_ZRAM"; then
    log_info "Zram already configured at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  local swap_manager
  swap_manager=$(detect_swap_manager)
  log_info "Detected swap manager: $swap_manager."

  # ---- capture pre-state (so uninstall can fully revert) ----
  # zram-tools install/remove is owned by packages/package-zram-tools.sh
  # (its own status file tracks pre-install state and handles symmetric
  # uninstall). We only track config-file + service pre-state here.
  if systemctl is-enabled --quiet dphys-swapfile 2>/dev/null; then
    status_set "$STATUS_FILE" "COMPRESSED_SWAP_FW_PRE_DPHYS_ENABLED" "true"
  else
    status_set "$STATUS_FILE" "COMPRESSED_SWAP_FW_PRE_DPHYS_ENABLED" "false"
  fi
  if systemctl is-enabled --quiet zramswap.service 2>/dev/null; then
    status_set "$STATUS_FILE" "COMPRESSED_SWAP_FW_PRE_ZRAMSWAP_SERVICE_ENABLED" "true"
  else
    status_set "$STATUS_FILE" "COMPRESSED_SWAP_FW_PRE_ZRAMSWAP_SERVICE_ENABLED" "false"
  fi
  status_set "$STATUS_FILE" "COMPRESSED_SWAP_FW_SWAP_MANAGER_USED" "$swap_manager"

  # Snapshot existing files we may overwrite (backup_create skips missing files).
  local snap
  snap=$(backup_create "$II_ID" "$ZRAMSWAP_DEFAULTS" "$ZRAM_GENERATOR_CONF" "$RPI_SWAP_DROPIN")
  log_info "Backup snapshot: $snap."

  # zram-tools (apt package) is pulled in via II_DEPS — the scheduler
  # runs packages/package-zram-tools.sh before us. We just need it
  # available; no apt step here anymore.

  # ---- disable dphys-swapfile if requested and present ----
  if [[ $ZRAM_DISABLE_DPHYS_SWAPFILE == "true" ]] \
     && systemctl list-unit-files dphys-swapfile.service >/dev/null 2>&1 \
     && systemctl is-enabled --quiet dphys-swapfile 2>/dev/null; then
    log_info "Disabling dphys-swapfile (older SD-card swap)."
    sudo systemctl disable --now dphys-swapfile \
      || log_warn "Failed to disable dphys-swapfile (continuing)."
  fi

  # ---- write config files ----
  case $swap_manager in
    rpi-swap)
      log_info "Writing $RPI_SWAP_DROPIN."
      sudo mkdir -p "$(dirname "$RPI_SWAP_DROPIN")"
      local ram_mult
      ram_mult=$(awk "BEGIN { printf \"%.2f\", $ZRAM_PERCENT_OF_RAM / 100 }")
      sudo tee "$RPI_SWAP_DROPIN" >/dev/null <<EOF
# Generated by installicious install-zram. Edit config/zram.config and re-run.
[Main]
Mechanism=zram

[Zram]
RamMultiplier=${ram_mult}
EOF

      log_info "Writing $ZRAM_GENERATOR_CONF for compression algo."
      sudo tee "$ZRAM_GENERATOR_CONF" >/dev/null <<EOF
# Generated by installicious install-zram (algo for rpi-swap-managed zram0).
[zram0]
compression-algorithm = ${ZRAM_COMPRESSION_ALGO}
swap-priority = ${ZRAM_SWAP_PRIORITY}
EOF

      if systemctl is-enabled --quiet zramswap.service 2>/dev/null; then
        log_info "Disabling zramswap.service (conflicts with rpi-swap)."
        sudo systemctl disable --now zramswap.service 2>/dev/null || true
      fi

      log_info "Reconfiguring /dev/zram0 to match new config."
      zram_reset_devices
      sudo systemctl daemon-reload
      sleep 1
      sudo systemctl start dev-zram0.swap 2>/dev/null \
        || log_warn "Live restart of dev-zram0.swap failed; will verify state and request reboot if needed."
      ;;

    zram-tools)
      log_info "Writing $ZRAMSWAP_DEFAULTS."
      sudo tee "$ZRAMSWAP_DEFAULTS" >/dev/null <<EOF
# Generated by installicious install-zram. Edit config/zram.config and re-run.
PERCENTAGE=${ZRAM_PERCENT_OF_RAM}
ALGO=${ZRAM_COMPRESSION_ALGO}
PRIORITY=${ZRAM_SWAP_PRIORITY}
EOF

      log_info "Restarting zramswap.service to apply config."
      zram_reset_devices
      sudo systemctl daemon-reload
      sudo systemctl restart zramswap.service \
        || log_warn "zramswap.service restart returned non-zero; will verify state and request reboot if needed."
      ;;
  esac

  # ---- verify the live device matches the configured size + algo ----
  # The kernel sometimes refuses to reset /dev/zram0 cleanly (busy device,
  # stale boot-time generator state, etc.). When that happens, the live
  # restart appears to "succeed" but the device is still on its previous
  # config. Catch that here so we don't mark the feature complete on a
  # half-applied state — if the live device doesn't match, request a
  # reboot. Boot-time generator picks up the new config cleanly.
  if _zram_verify_active_config; then
    log_ok "Zram swap live: ${swap_manager}, ${ZRAM_PERCENT_OF_RAM}% of RAM, ${ZRAM_COMPRESSION_ALGO}."
    status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_ZRAM"
    status_set "$STATUS_FILE" "COMPRESSED_SWAP_STATUS" "Completed"
    echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully configured ZRAM swap."
    return 0
  fi

  # Device didn't come up matching the new config. Mark complete now (the
  # config files are written; resume just needs a fresh boot to pick them
  # up), then request_reboot. Scheduler will halt the queue and the
  # systemd resume unit will run any remaining items after the reboot.
  log_warn "Live /dev/zram0 doesn't match configured size/algo. Requesting reboot to apply cleanly."
  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_ZRAM"
  status_set "$STATUS_FILE" "COMPRESSED_SWAP_STATUS" "Pending Reboot"
  echo -e "[  \e[0;32mOK\e[0m  ] ZRAM config written; reboot will be triggered to apply."
  request_reboot "zram swap config requires reboot to apply cleanly" "$II_ID"
  return $EXIT_REBOOT
}

# _zram_verify_active_config — rc=0 if the live /dev/zram0 reflects
# $ZRAM_PERCENT_OF_RAM + $ZRAM_COMPRESSION_ALGO, rc=1 otherwise. ±10%
# size tolerance because the actual zram disksize is computed from the
# kernel's view of total RAM, not /proc/meminfo's MemTotal (a few MB
# off due to reserved memory).
#
# ZRAM_SKIP_LIVE_VERIFY=true forces rc=0 — used by the round-trip test
# harness where /dev/zram0 doesn't exist (Windows/git-bash, no zram
# kernel module). Production callers leave the env unset.
_zram_verify_active_config() {
  [[ ${ZRAM_SKIP_LIVE_VERIFY:-} == "true" ]] && return 0
  [[ -b /dev/zram0 ]] || { log_warn "_zram_verify: /dev/zram0 not present."; return 1; }

  local actual_bytes
  actual_bytes=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  if (( actual_bytes == 0 )); then
    log_warn "_zram_verify: /dev/zram0 disksize is 0 (device not initialized)."
    return 1
  fi

  local actual_mb ram_mb expected_mb min_mb max_mb
  actual_mb=$(( actual_bytes / 1024 / 1024 ))
  ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  expected_mb=$(( ram_mb * ZRAM_PERCENT_OF_RAM / 100 ))
  min_mb=$(( expected_mb * 90 / 100 ))
  max_mb=$(( expected_mb * 110 / 100 ))

  local actual_algo
  actual_algo=$(awk -F'[][]' '/\[/{print $2; exit}' /sys/block/zram0/comp_algorithm 2>/dev/null)

  if (( actual_mb < min_mb || actual_mb > max_mb )); then
    log_warn "_zram_verify: live zram size ${actual_mb}M outside expected range ${min_mb}-${max_mb}M."
    return 1
  fi
  if [[ -n $ZRAM_COMPRESSION_ALGO && "$actual_algo" != "$ZRAM_COMPRESSION_ALGO" ]]; then
    log_warn "_zram_verify: live zram algo '$actual_algo' != configured '$ZRAM_COMPRESSION_ALGO'."
    return 1
  fi
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Zram is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for zram; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  local swap_manager pre_dphys pre_zramswap
  swap_manager=$(status_get "$STATUS_FILE" "COMPRESSED_SWAP_FW_SWAP_MANAGER_USED")
  pre_dphys=$(status_get "$STATUS_FILE" "COMPRESSED_SWAP_FW_PRE_DPHYS_ENABLED")
  pre_zramswap=$(status_get "$STATUS_FILE" "COMPRESSED_SWAP_FW_PRE_ZRAMSWAP_SERVICE_ENABLED")

  log_info "Reverting zram setup (manager was $swap_manager)."

  # 1. Restore or remove the config files we touched.
  if backup_restore_or_remove "$II_ID" \
       "$ZRAMSWAP_DEFAULTS" "$ZRAM_GENERATOR_CONF" "$RPI_SWAP_DROPIN"; then
    log_info "Config files restored from backup (or removed if not pre-existing)."
  else
    log_warn "No backup snapshot found; deleting config files we may have created."
    [[ -f $RPI_SWAP_DROPIN ]] && sudo rm -f "$RPI_SWAP_DROPIN"
  fi

  # 2. If we disabled dphys-swapfile and it was previously enabled, re-enable it.
  if [[ $pre_dphys == "true" ]] \
     && systemctl list-unit-files dphys-swapfile.service >/dev/null 2>&1; then
    log_info "Re-enabling dphys-swapfile (was enabled pre-install)."
    sudo systemctl enable --now dphys-swapfile \
      || log_warn "Failed to re-enable dphys-swapfile."
  fi

  # 3. If we disabled zramswap.service (rpi-swap path) and it was enabled before, re-enable.
  if [[ $pre_zramswap == "true" ]] \
     && systemctl list-unit-files zramswap.service >/dev/null 2>&1; then
    log_info "Re-enabling zramswap.service (was enabled pre-install)."
    sudo systemctl enable --now zramswap.service \
      || log_warn "Failed to re-enable zramswap.service."
  fi

  # 4. Reset live zram device so the restored config takes effect (or device shuts down).
  log_info "Resetting /dev/zram0 to apply reverted config."
  zram_reset_devices
  sudo systemctl daemon-reload

  # zram-tools removal is owned by packages/package-zram-tools.sh — its
  # uninstall path checks its own pre-install record and apt-removes the
  # package only if it wasn't there before installicious touched the
  # system. The framework runs both uninstalls in scheduler order.

  status_mark_uninstalled "$II_ID"
  status_set "$STATUS_FILE" "COMPRESSED_SWAP_STATUS" "Uninstalled"
  log_ok "Zram swap reverted to pre-install state."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled ZRAM."
  return 0
}

do_verify() { verify_generic "$II_ID"; }

if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "verify" ]]; then
  do_verify
else
  do_uninstall
fi
exit $?
