#!/bin/bash

# Module:      RAM Logging
# Description: Reduces SD-card wear by mounting /var/log in RAM via
#              log2ram. The user picks a profile — backend (tmpfs or
#              ZRAM) crossed with sync mode (volatile / shutdown /
#              periodic / both) — and the feature applies the matching
#              log2ram.conf, systemd timer state, ExecStop drop-in,
#              logrotate tuning, and journald drop-in.
#
#              The apt package itself (log2ram) is pulled in via
#              II_DEPS — packages/package-log2ram.sh handles install
#              + the Bookworm azlux third-party repo dance.
#
# Profiles:
#   tmpfs-volatile   /var/log on plain tmpfs, no sync (logs lost on every reboot)
#   tmpfs-shutdown   /var/log on plain tmpfs, sync to disk on shutdown
#   tmpfs-periodic   /var/log on plain tmpfs, hourly sync to disk
#   tmpfs-both       /var/log on plain tmpfs, hourly + on-shutdown sync
#   zram-*           same matrix but /var/log on a compressed-RAM
#                    block device (zram1 — separate from the swap
#                    zram0 used by feature-compressed-swap)
#
# Reboot semantics: changing log2ram's backend (tmpfs ↔ zram) requires
# unmounting /var/log, which can't happen while the system uses it.
# The feature always request_reboot's after applying config so the
# next boot picks up cleanly. Status tracks pending-reboot, the
# scheduler halts and the systemd resume continues the queue.
#
# Bump II_VERSION to force a re-run.

# === II_MANIFEST_BEGIN ===
II_ID="ram-logging"
II_TITLE="Logging in RAM (log2ram)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="log2ram"
II_REQUIRES_REBOOT="conditional"
II_EDITABLE_CONFIG="RAMLOG_PROFILE RAMLOG_SIZE_MB RAMLOG_COMPRESSION_ALGO"
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

FILE_CONFIG_RAMLOG="$PATH_CONFIG/ram-logging.config"
[[ -f $FILE_CONFIG_RAMLOG ]] && source "$FILE_CONFIG_RAMLOG"
declare -F state_apply_menu_overrides >/dev/null && state_apply_menu_overrides

# Source choices file so _default_<KEY> helpers exist.
FILE_CHOICES_RAMLOG="${PATH_FEATURES:-features}/feature-ram-logging.choices.sh"
[[ -f $FILE_CHOICES_RAMLOG ]] && source "$FILE_CHOICES_RAMLOG"

# Resolve any blank config values via the smart-default helpers; same
# pattern as feature-compressed-swap. Ensures editor display and
# install-time apply agree on values.
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
_resolve_default RAMLOG_PROFILE          "zram-both"
_resolve_default RAMLOG_SIZE_MB          128
_resolve_default RAMLOG_COMPRESSION_ALGO zstd

# Parse "<backend>-<sync>" — backend is the part before the first
# hyphen, sync is everything after. Robust to "-" appearing inside the
# sync portion if we ever extend it.
RAMLOG_BACKEND="${RAMLOG_PROFILE%%-*}"
RAMLOG_SYNC="${RAMLOG_PROFILE#*-}"

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

STATUS_FILE=$(status_file_for "$II_ID")

LOG2RAM_CONF="${LOG2RAM_CONF:-/etc/log2ram.conf}"
LOG2RAM_TIMER_DROPIN_DIR="${LOG2RAM_TIMER_DROPIN_DIR:-/etc/systemd/system/log2ram-daily.timer.d}"
LOG2RAM_TIMER_DROPIN="${LOG2RAM_TIMER_DROPIN:-$LOG2RAM_TIMER_DROPIN_DIR/installicious-hourly.conf}"
LOG2RAM_SERVICE_DROPIN_DIR="${LOG2RAM_SERVICE_DROPIN_DIR:-/etc/systemd/system/log2ram.service.d}"
LOG2RAM_SERVICE_DROPIN="${LOG2RAM_SERVICE_DROPIN:-$LOG2RAM_SERVICE_DROPIN_DIR/installicious-no-shutdown-sync.conf}"
LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.conf}"
JOURNALD_DROPIN_DIR="${JOURNALD_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNALD_DROPIN="${JOURNALD_DROPIN:-$JOURNALD_DROPIN_DIR/50-installicious-ram-logging.conf}"

_should_enable_timer() {
  case "$RAMLOG_SYNC" in periodic|both) return 0 ;; *) return 1 ;; esac
}

_should_skip_shutdown_sync() {
  case "$RAMLOG_SYNC" in volatile|periodic) return 0 ;; *) return 1 ;; esac
}

_zram_backed() {
  [[ $RAMLOG_BACKEND == "zram" ]]
}

# Trim oversize /var/log entries before enabling log2ram — log2ram
# refuses to start if the existing /var/log content exceeds SIZE.
_trim_var_log() {
  log_info "Trimming rotated logs to fit RAM budget."
  sudo find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.[0-9]" -o -name "*.old" \) -delete 2>/dev/null || true
  sudo journalctl --vacuum-size=20M >/dev/null 2>&1 || true
}

_write_log2ram_conf() {
  local zl2r="false" log_disk_mb=$((RAMLOG_SIZE_MB * 2))
  _zram_backed && zl2r="true"

  log_info "Writing $LOG2RAM_CONF (size=${RAMLOG_SIZE_MB}M, ZL2R=${zl2r}, COMP_ALG=${RAMLOG_COMPRESSION_ALGO})."
  # log2ram ships a stock conf with the keys we want already present;
  # sed-substitute them and append any that are missing (Trixie's 1.7.2
  # shipped a stripped-down conf in some builds).
  sudo sed -i \
    -e "s|^SIZE=.*|SIZE=${RAMLOG_SIZE_MB}M|" \
    -e "s|^USE_RSYNC=.*|USE_RSYNC=true|" \
    -e "s|^MAIL=.*|MAIL=false|" \
    -e "s|^PRIORITY=.*|PRIORITY=15|" \
    -e "s|^ZL2R=.*|ZL2R=${zl2r}|" \
    -e "s|^LOG_DISK_SIZE=.*|LOG_DISK_SIZE=${log_disk_mb}M|" \
    -e "s|^COMP_ALG=.*|COMP_ALG=${RAMLOG_COMPRESSION_ALGO}|" \
    "$LOG2RAM_CONF"

  _ensure_kv() {
    local key=$1 val=$2
    if ! sudo grep -qE "^${key}=" "$LOG2RAM_CONF" 2>/dev/null; then
      echo "${key}=${val}" | sudo tee -a "$LOG2RAM_CONF" >/dev/null
    fi
  }
  _ensure_kv SIZE          "${RAMLOG_SIZE_MB}M"
  _ensure_kv USE_RSYNC     true
  _ensure_kv MAIL          false
  _ensure_kv PRIORITY      15
  _ensure_kv ZL2R          "$zl2r"
  _ensure_kv LOG_DISK_SIZE "${log_disk_mb}M"
  _ensure_kv COMP_ALG      "$RAMLOG_COMPRESSION_ALGO"

  # log2ram packages have at times shipped a duplicate JOURNALD_AWARE=
  # line. Drop dupes (last wins anyway, just confusing in diffs).
  sudo awk '!seen[$0]++ || $0 !~ /^JOURNALD_AWARE=/' "$LOG2RAM_CONF" | sudo tee "$LOG2RAM_CONF.tmp" >/dev/null \
    && sudo mv -f "$LOG2RAM_CONF.tmp" "$LOG2RAM_CONF"
}

_write_timer_dropin() {
  if _should_enable_timer; then
    log_info "Enabling log2ram-daily.timer with hourly cadence."
    sudo mkdir -p "$LOG2RAM_TIMER_DROPIN_DIR"
    sudo tee "$LOG2RAM_TIMER_DROPIN" >/dev/null <<'EOF'
# Generated by installicious feature-ram-logging.
# Override log2ram-daily.timer's default OnCalendar=daily to hourly so
# less log data is at risk of being lost on a power failure.
[Timer]
OnCalendar=
OnCalendar=hourly
EOF
  else
    log_info "Sync mode '$RAMLOG_SYNC' — disabling log2ram-daily.timer."
    [[ -f $LOG2RAM_TIMER_DROPIN ]] && sudo rm -f "$LOG2RAM_TIMER_DROPIN"
  fi
}

_write_service_dropin() {
  if _should_skip_shutdown_sync; then
    log_info "Sync mode '$RAMLOG_SYNC' — drop-in to skip log2ram's shutdown sync."
    sudo mkdir -p "$LOG2RAM_SERVICE_DROPIN_DIR"
    sudo tee "$LOG2RAM_SERVICE_DROPIN" >/dev/null <<'EOF'
# Generated by installicious feature-ram-logging.
# Skip log2ram's ExecStop sync (which writes RAM /var/log back to the SD
# card on graceful shutdown). The empty ExecStop= line clears the unit's
# default; the /bin/true keeps systemd happy with at least one ExecStop.
[Service]
ExecStop=
ExecStop=/bin/true
EOF
  else
    log_info "Sync mode '$RAMLOG_SYNC' — keeping log2ram's default ExecStop (shutdown sync on)."
    [[ -f $LOG2RAM_SERVICE_DROPIN ]] && sudo rm -f "$LOG2RAM_SERVICE_DROPIN"
  fi
}

_write_logrotate_conf() {
  log_info "Tuning logrotate for RAM-backed /var/log (maxsize 5M, xz)."
  sudo tee "$LOGROTATE_CONF" >/dev/null <<'EOF'
# Tuned by installicious feature-ram-logging for RAM-backed /var/log.
daily
rotate 4
create
compress
compresscmd /usr/bin/xz
compressext .xz
compressoptions -6
maxsize 5M

include /etc/logrotate.d
EOF

  # Move the daily logrotate cron entry to hourly so we rotate before
  # /var/log can fill the RAM budget.
  if [[ -f /etc/cron.daily/logrotate && ! -f /etc/cron.hourly/logrotate ]]; then
    sudo mv /etc/cron.daily/logrotate /etc/cron.hourly/logrotate
  fi
}

_write_journald_dropin() {
  log_info "Configuring journald to persist under /var/log/journal (sized 50M)."
  sudo mkdir -p "$JOURNALD_DROPIN_DIR"
  sudo tee "$JOURNALD_DROPIN" >/dev/null <<'EOF'
# Generated by installicious feature-ram-logging.
# Persist the journal under /var/log/journal so log2ram's RAM caching
# covers it. SystemMaxUse caps the journal share of the RAM budget.
[Journal]
Storage=persistent
SystemMaxUse=50M
EOF
  sudo mkdir -p /var/log/journal
}

_apply_systemd_state() {
  log_info "Applying systemd state for log2ram service + timer."
  sudo systemctl daemon-reload 2>/dev/null || true
  sudo systemctl enable log2ram.service 2>/dev/null || true

  if _should_enable_timer; then
    sudo systemctl enable log2ram-daily.timer 2>/dev/null || true
  else
    sudo systemctl disable --now log2ram-daily.timer 2>/dev/null || true
  fi

  # Don't try to stop/start log2ram.service live — switching backend
  # requires /var/log to be unmounted, which means a reboot anyway.
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_RAMLOG"; then
    log_info "RAM logging already configured at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  if ! command -v log2ram >/dev/null 2>&1; then
    log_fail "log2ram not found in PATH. The package-log2ram II_DEP should have installed it."
    status_mark_failed "$II_ID" "log2ram binary missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not find log2ram. Try: sudo apt install log2ram"
    return 1
  fi

  # Pre-state: snapshot the conf files we'll overwrite + which units
  # were already enabled, so uninstall can restore.
  if systemctl is-enabled --quiet log2ram-daily.timer 2>/dev/null; then
    status_set "$STATUS_FILE" "RAM_LOGGING_FW_PRE_TIMER_ENABLED" "true"
  else
    status_set "$STATUS_FILE" "RAM_LOGGING_FW_PRE_TIMER_ENABLED" "false"
  fi
  status_set "$STATUS_FILE" "RAM_LOGGING_FW_PROFILE_APPLIED" "$RAMLOG_PROFILE"
  status_set "$STATUS_FILE" "RAM_LOGGING_FW_SIZE_MB_APPLIED" "$RAMLOG_SIZE_MB"

  local snap
  snap=$(backup_create "$II_ID" "$LOG2RAM_CONF" "$LOGROTATE_CONF")
  log_info "Backup snapshot: $snap."

  _trim_var_log
  _write_log2ram_conf
  _write_timer_dropin
  _write_service_dropin
  _write_logrotate_conf
  _write_journald_dropin
  _apply_systemd_state

  # Switching log2ram's backend (tmpfs ↔ zram) or first-time enabling
  # requires /var/log to be re-mounted, which can't happen while the
  # system uses it. Always reboot to apply cleanly.
  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_RAMLOG"
  status_set "$STATUS_FILE" "RAM_LOGGING_STATUS" "Pending Reboot"
  log_info "RAM logging config written ($RAMLOG_PROFILE, ${RAMLOG_SIZE_MB}M); reboot will be triggered to apply."
  echo -e "[  \e[0;32mOK\e[0m  ] RAM logging configured ($RAMLOG_PROFILE, ${RAMLOG_SIZE_MB}M); reboot will be triggered."
  request_reboot "log2ram backend change requires reboot" "$II_ID"
  return $EXIT_REBOOT
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] RAM logging is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for ram-logging; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  local pre_timer_enabled
  pre_timer_enabled=$(status_get "$STATUS_FILE" "RAM_LOGGING_FW_PRE_TIMER_ENABLED")

  log_info "Reverting RAM logging setup."

  # 1. Disable units we may have enabled.
  sudo systemctl disable --now log2ram-daily.timer 2>/dev/null || true
  if [[ $pre_timer_enabled == "true" ]] \
     && systemctl list-unit-files log2ram-daily.timer >/dev/null 2>&1; then
    log_info "Re-enabling log2ram-daily.timer (was enabled pre-install)."
    sudo systemctl enable --now log2ram-daily.timer 2>/dev/null || true
  fi

  # 2. Remove our drop-ins.
  [[ -f $LOG2RAM_TIMER_DROPIN   ]] && sudo rm -f "$LOG2RAM_TIMER_DROPIN"
  [[ -f $LOG2RAM_SERVICE_DROPIN ]] && sudo rm -f "$LOG2RAM_SERVICE_DROPIN"
  [[ -f $JOURNALD_DROPIN        ]] && sudo rm -f "$JOURNALD_DROPIN"
  sudo rmdir "$LOG2RAM_TIMER_DROPIN_DIR"   2>/dev/null || true
  sudo rmdir "$LOG2RAM_SERVICE_DROPIN_DIR" 2>/dev/null || true

  # 3. Restore configs we overwrote.
  if backup_restore_or_remove "$II_ID" "$LOG2RAM_CONF" "$LOGROTATE_CONF"; then
    log_info "log2ram.conf + logrotate.conf restored from backup (or removed if not pre-existing)."
  else
    log_warn "No backup snapshot found for ram-logging."
  fi

  # 4. Move logrotate cron back to daily (we moved it to hourly).
  if [[ -f /etc/cron.hourly/logrotate && ! -f /etc/cron.daily/logrotate ]]; then
    sudo mv /etc/cron.hourly/logrotate /etc/cron.daily/logrotate
  fi

  # log2ram apt package + repo cleanup is owned by package-log2ram —
  # its --uninstall path handles the apt remove + azlux repo removal
  # symmetric to install. Scheduler runs both in order.

  sudo systemctl daemon-reload 2>/dev/null || true

  status_mark_uninstalled "$II_ID"
  status_set "$STATUS_FILE" "RAM_LOGGING_STATUS" "Uninstalled"
  log_warn "Reboot recommended so /var/log unmounts cleanly back to the SD card."
  echo -e "[  \e[0;32mOK\e[0m  ] RAM logging reverted; reboot recommended."
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
