#!/bin/bash

# Module:      ZRAM Installer
# Description: Sets up compressed RAM swap (zram) using whichever manager fits
#              the OS:
#                - rpi-swap (preinstalled on Pi OS Trixie)
#                - zram-tools (Bullseye, Bookworm)
#              Disables dphys-swapfile (older SD-card swap) if present.
#              Configurable via config/zram.config.
#
#              On install we capture pre-state — whether zram-tools/rpi-swap
#              were already there, whether dphys-swapfile was enabled, whether
#              zramswap.service was enabled, and a backup snapshot of any config
#              files we'll replace. --uninstall reverses those, restoring the
#              system as closely as possible to its pre-install state.
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
II_ID="zram"
II_TITLE="ZRAM swap"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="conditional"
II_EDITABLE_CONFIG="ZRAM_PERCENT_OF_RAM ZRAM_COMPRESSION_ALGO ZRAM_SWAP_PRIORITY"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/backup.sh

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)        MODE="install" ;;
    --uninstall)      MODE="uninstall" ;;
    --restore-backup) MODE="uninstall" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

FILE_CONFIG_ZRAM="$PATH_CONFIG/zram.config"
[[ -f $FILE_CONFIG_ZRAM ]] && source "$FILE_CONFIG_ZRAM"
# Apply user edits from the menu_edit_config screen (Phase 2). Sourced after
# the baseline config so menu edits win for this run.
declare -F state_apply_menu_overrides >/dev/null && state_apply_menu_overrides
ZRAM_PERCENT_OF_RAM="${ZRAM_PERCENT_OF_RAM:-50}"
ZRAM_COMPRESSION_ALGO="${ZRAM_COMPRESSION_ALGO:-zstd}"
ZRAM_SWAP_PRIORITY="${ZRAM_SWAP_PRIORITY:-100}"
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
  if apt_is_installed zram-tools; then
    status_set "$STATUS_FILE" "ZRAM_FW_PRE_ZRAM_TOOLS_INSTALLED" "true"
  else
    status_set "$STATUS_FILE" "ZRAM_FW_PRE_ZRAM_TOOLS_INSTALLED" "false"
  fi
  if systemctl is-enabled --quiet dphys-swapfile 2>/dev/null; then
    status_set "$STATUS_FILE" "ZRAM_FW_PRE_DPHYS_ENABLED" "true"
  else
    status_set "$STATUS_FILE" "ZRAM_FW_PRE_DPHYS_ENABLED" "false"
  fi
  if systemctl is-enabled --quiet zramswap.service 2>/dev/null; then
    status_set "$STATUS_FILE" "ZRAM_FW_PRE_ZRAMSWAP_SERVICE_ENABLED" "true"
  else
    status_set "$STATUS_FILE" "ZRAM_FW_PRE_ZRAMSWAP_SERVICE_ENABLED" "false"
  fi
  status_set "$STATUS_FILE" "ZRAM_FW_SWAP_MANAGER_USED" "$swap_manager"

  # Snapshot existing files we may overwrite (backup_create skips missing files).
  local snap
  snap=$(backup_create "$II_ID" "$ZRAMSWAP_DEFAULTS" "$ZRAM_GENERATOR_CONF" "$RPI_SWAP_DROPIN")
  log_info "Backup snapshot: $snap."

  # ---- install zram-tools if needed ----
  if [[ $swap_manager == "zram-tools" ]]; then
    apt_ensure_installed zram-tools
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      log_fail "Failed to install zram-tools." "$rc"
      status_mark_failed "$II_ID" "apt install zram-tools failed (code $rc)"
      status_set "$STATUS_FILE" "ZRAM_STATUS" "Error"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install zram-tools. Error Code: $rc."
      return $rc
    fi
  fi

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
        || log_warn "Live restart failed; reboot to pick up config cleanly."
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
        || log_warn "zramswap.service restart returned non-zero; check 'systemctl status zramswap'."
      ;;
  esac

  log_ok "Zram swap configured (${swap_manager}, ${ZRAM_PERCENT_OF_RAM}% of RAM, ${ZRAM_COMPRESSION_ALGO})."
  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_ZRAM"
  status_set "$STATUS_FILE" "ZRAM_STATUS" "Completed"
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully configured ZRAM swap."
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

  local swap_manager pre_zram_tools pre_dphys pre_zramswap
  swap_manager=$(status_get "$STATUS_FILE" "ZRAM_FW_SWAP_MANAGER_USED")
  pre_zram_tools=$(status_get "$STATUS_FILE" "ZRAM_FW_PRE_ZRAM_TOOLS_INSTALLED")
  pre_dphys=$(status_get "$STATUS_FILE" "ZRAM_FW_PRE_DPHYS_ENABLED")
  pre_zramswap=$(status_get "$STATUS_FILE" "ZRAM_FW_PRE_ZRAMSWAP_SERVICE_ENABLED")

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

  # 5. If we installed zram-tools, remove it.
  if [[ $pre_zram_tools == "false" ]] && apt_is_installed zram-tools; then
    log_info "Removing zram-tools (we installed it)."
    apt_remove zram-tools \
      || log_warn "apt remove zram-tools returned non-zero (continuing)."
  fi

  status_mark_uninstalled "$II_ID"
  status_set "$STATUS_FILE" "ZRAM_STATUS" "Uninstalled"
  log_ok "Zram swap reverted to pre-install state."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled ZRAM."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
