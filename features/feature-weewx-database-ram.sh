#!/bin/bash

# Module:      WeeWX database on a zram-backed ext4 filesystem
# Description: Moves the WeeWX SQLite database off the SD card onto a
#              dedicated zram device, with VALIDATED hourly snapshots,
#              snapshot rotation, and a clean save on shutdown — sparing
#              the SD card from continuous WeeWX writes.
#
#              On install:
#                1. Stops weewx if it's running; rsync /var/lib/weewx
#                   to /var/lib/weewx.hdd (persistent mirror on SD).
#                2. Writes /etc/weewx-ramdisk.conf with the chosen
#                   ZRAM_SIZE (sized from the current DB) and ZRAM_ALGO
#                   (zstd on Pi 4/5, lz4 on older). ROTATION_COUNT comes
#                   from $WEEWX_DB_ROTATIONS in config/weewx.config.
#                3. Installs three helper scripts in /usr/local/sbin/
#                   (weewx-ram-setup / -save / -teardown) and three
#                   systemd units + a drop-in for weewx.service.
#                4. Enables the unit + the hourly snapshot timer,
#                   starts the ramdisk service (which restores from the
#                   newest validated snapshot), and restarts weewx if
#                   it was running.
#
#              Snapshot integrity is validated both on save (refuse to
#              overwrite a good snapshot with a corrupt live DB) and on
#              restore (walk the rotation .1, .2, ... until one passes
#              quick_check). Refuses to boot rather than hand a corrupt
#              DB to weewx.
#
#              Symmetric uninstall: stops + disables everything, rsyncs
#              the persistent mirror back to /var/lib/weewx, removes all
#              installed files, restarts weewx.

# === II_MANIFEST_BEGIN ===
II_ID="weewx-database-ram"
II_TITLE="WeeWX database on zram (validated snapshots)"
II_CATEGORY="feature"
II_VERSION="2"
II_DEPS="weewx"
II_REQUIRES_REBOOT="conditional"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_APT_PACKAGES="sqlite3 rsync util-linux zram-tools"
II_EDITABLE_CONFIG="WEEWX_DB_DIR WEEWX_DB_HDD_DIR WEEWX_DB_ROTATIONS WEEWX_DB_ZRAM_SIZE"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh
source lib/apt.sh
source lib/installer_apt.sh
source lib/verify.sh

FILE_CONFIG_WEEWX="${PATH_CONFIG:-config}/weewx.config"
[[ -f $FILE_CONFIG_WEEWX ]] && source "$FILE_CONFIG_WEEWX"
state_apply_menu_overrides
WEEWX_DB_DIR="${WEEWX_DB_DIR:-/var/lib/weewx}"
WEEWX_DB_HDD_DIR="${WEEWX_DB_HDD_DIR:-/var/lib/weewx.hdd}"
WEEWX_DB_ROTATIONS="${WEEWX_DB_ROTATIONS:-5}"
WEEWX_DB_ZRAM_SIZE="${WEEWX_DB_ZRAM_SIZE:-AUTO}"

RAMDISK_CONF="/etc/weewx-ramdisk.conf"
SETUP_BIN="/usr/local/sbin/weewx-ram-setup"
SAVE_BIN="/usr/local/sbin/weewx-ram-save"
TEARDOWN_BIN="/usr/local/sbin/weewx-ram-teardown"
UNIT_MAIN="/etc/systemd/system/weewx-ramdisk.service"
UNIT_SAVE="/etc/systemd/system/weewx-ramdisk-save.service"
TIMER_SAVE="/etc/systemd/system/weewx-ramdisk-save.timer"
DROPIN_DIR="/etc/systemd/system/weewx.service.d"
DROPIN_FILE="${DROPIN_DIR}/ramdisk.conf"

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

STATUS_FILE=$(status_file_for "$II_ID")

# Pi-model-aware zram-algo + ZRAM_SIZE computation. Mirrors the original
# scripts/weewx-database-ramdisk.sh sizing: 1.5x current DB size, rounded
# up to 128M, floor 256M. zstd compresses denser but costs more CPU; we
# only use it on Pi 4-class hardware that can absorb the overhead.
# WEEWX_DB_ZRAM_SIZE (in config/weewx.config) is the manual override:
# "AUTO" (case-insensitive) or empty → compute. Anything else (e.g.
# "1024M") wins over the auto-sized value.
compute_ram_plan() {
  local pi_model="unknown"
  [[ -r /proc/device-tree/model ]] && pi_model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
  case "$pi_model" in
    *"Pi 5"*|*"Pi 4"*|*"Compute Module 4"*|*"Pi 400"*) ZRAM_ALGO=zstd ;;
    *)                                                  ZRAM_ALGO=lz4  ;;
  esac
  DETECTED_PI_MODEL="$pi_model"

  local db_path="${WEEWX_DB_DIR}/weewx.sdb"
  local db_mb=0
  [[ -f $db_path ]] && db_mb=$(( $(stat -c %s "$db_path") / 1024 / 1024 ))
  DETECTED_DB_MB=$db_mb

  local zram_override="${WEEWX_DB_ZRAM_SIZE^^}"
  if [[ -n $zram_override && $zram_override != "AUTO" ]]; then
    ZRAM_SIZE="$WEEWX_DB_ZRAM_SIZE"
    ZRAM_SIZE_SOURCE="manual override (WEEWX_DB_ZRAM_SIZE)"
  else
    local zram_mb=512
    if (( db_mb > 0 )); then
      zram_mb=$(( (db_mb * 3 / 2 + 127) / 128 * 128 ))
      (( zram_mb < 256 )) && zram_mb=256
    fi
    ZRAM_SIZE="${zram_mb}M"
    ZRAM_SIZE_SOURCE="auto-computed from ${db_mb}M DB"
  fi
}

write_ramdisk_conf() {
  if [[ -f $RAMDISK_CONF ]] && [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up existing $RAMDISK_CONF."
    backup_create "$II_ID" "$RAMDISK_CONF" >/dev/null || log_warn "backup_create failed."
  fi
  log_info "Writing $RAMDISK_CONF (zram ${ZRAM_SIZE} ${ZRAM_ALGO}, rotation ${WEEWX_DB_ROTATIONS})."
  sudo tee "$RAMDISK_CONF" >/dev/null <<EOF
# Generated by feature-weewx-database-ram.sh for ${DETECTED_PI_MODEL}
# Adjust ZRAM_SIZE if 'df -h ${WEEWX_DB_DIR}' approaches full, or if actual
# RAM usage (seen in 'zramctl') is comfortably lower than expected.
ZRAM_SIZE=${ZRAM_SIZE}
ZRAM_ALGO=${ZRAM_ALGO}
MOUNT=${WEEWX_DB_DIR}
PERSIST=${WEEWX_DB_HDD_DIR}
OWNER=weewx:weewx
# How many rotated snapshots to keep on the SD card (weewx.sdb.1 ... .N).
# Raise for more fallback depth at the cost of SD space (1x DB per slot).
ROTATION_COUNT=${WEEWX_DB_ROTATIONS}
EOF
}

write_helpers() {
  log_info "Writing helper scripts under /usr/local/sbin/."

  # --- boot-time restore: validated snapshot -> zram -----------------------
  sudo tee "$SETUP_BIN" >/dev/null <<'SETUP_EOF'
#!/bin/bash
# Allocate a fresh zram device, mount it at $MOUNT, restore a VALIDATED
# snapshot from the SD-card mirror. Walks the rotation (.1, .2, ...) until
# one passes quick_check; refuses to start if NO snapshot validates.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/weewx-ramdisk.conf

ROTATION_COUNT="${ROTATION_COUNT:-5}"

if mountpoint -q "$MOUNT"; then
  logger -t weewx-ram "$MOUNT already mounted; skipping setup"
  exit 0
fi

ZDEV=$(zramctl --find --size "$ZRAM_SIZE" --algorithm "$ZRAM_ALGO")
echo "$ZDEV" > /run/weewx-ram.dev

# ext4 without a journal: the filesystem is ephemeral, so journaling only
# costs RAM and write amplification.
mkfs.ext4 -q -L weewx-ram -F -O ^has_journal "$ZDEV"
mkdir -p "$MOUNT"
mount -o noatime,nosuid "$ZDEV" "$MOUNT"

# Non-DB files first (configs, skins, stale HTML — small, no validation).
if [[ -d "$PERSIST" ]]; then
  rsync -aHAX --delete \
    --exclude='weewx.sdb' \
    --exclude='weewx.sdb.tmp' \
    --exclude='weewx.sdb.[0-9]*' \
    "${PERSIST}/" "${MOUNT}/"
fi

DBP="${PERSIST}/weewx.sdb"
CANDIDATES=("$DBP")
for (( i=1; i<=ROTATION_COUNT; i++ )); do
  CANDIDATES+=("${DBP}.${i}")
done

VALID=""
for candidate in "${CANDIDATES[@]}"; do
  [[ -f "$candidate" ]] || continue
  logger -t weewx-ram "Validating candidate $candidate"
  CHECK=$(sqlite3 -bail "$candidate" 'PRAGMA quick_check(1);' 2>&1 || true)
  if [[ "$CHECK" == "ok" ]]; then
    VALID="$candidate"; break
  else
    logger -p user.warning -t weewx-ram \
      "Snapshot $candidate FAILED quick_check; trying older. Report: $CHECK"
  fi
done

if [[ -n "$VALID" ]]; then
  cp -f --preserve=mode,ownership,timestamps "$VALID" "${MOUNT}/weewx.sdb"
  chown "$OWNER" "${MOUNT}/weewx.sdb"
  if [[ "$VALID" != "$DBP" ]]; then
    logger -p user.warning -t weewx-ram \
      "Restored from FALLBACK snapshot $VALID (primary was corrupt)"
  else
    logger -t weewx-ram "Restored primary snapshot $VALID"
  fi
elif [[ -f "$DBP" || -f "${DBP}.1" ]]; then
  logger -p user.crit -t weewx-ram \
    "ALL DB snapshots failed integrity_check. Refusing to restore."
  umount "$MOUNT" || true
  if [[ -b "$ZDEV" ]]; then
    zramctl --reset "$ZDEV" 2>/dev/null || true
  fi
  rm -f /run/weewx-ram.dev
  exit 10
else
  logger -t weewx-ram "No existing snapshot at $DBP; starting fresh"
fi

chown -R "$OWNER" "$MOUNT"
logger -t weewx-ram "Mounted $ZDEV ($ZRAM_SIZE $ZRAM_ALGO) at $MOUNT"
SETUP_EOF

  # --- hourly + shutdown snapshot ------------------------------------------
  sudo tee "$SAVE_BIN" >/dev/null <<'SAVE_EOF'
#!/bin/bash
# Validated snapshot of the live DB to the SD-card mirror.
#   1. quick_check the live DB (refuse to overwrite good snapshot w/ garbage).
#   2. sqlite3 .backup to a .tmp file.
#   3. integrity_check the .tmp (discard if it fails).
#   4. Rotate: weewx.sdb -> .1 -> .2 -> ...
#   5. Atomic mv promote.
#   6. rsync non-DB files.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/weewx-ramdisk.conf

ROTATION_COUNT="${ROTATION_COUNT:-5}"

if ! mountpoint -q "$MOUNT"; then
  logger -t weewx-ram "$MOUNT not mounted; skipping save"
  exit 0
fi

mkdir -p "$PERSIST"

DB="${MOUNT}/weewx.sdb"
DBP="${PERSIST}/weewx.sdb"
TMP="${DBP}.tmp"
rm -f "$TMP"

if [[ -f "$DB" ]]; then
  LIVE_CHECK=$(sqlite3 -bail "$DB" 'PRAGMA quick_check(1);' 2>&1 || true)
  if [[ "$LIVE_CHECK" != "ok" ]]; then
    logger -p user.err -t weewx-ram \
      "LIVE DB FAILED quick_check — NOT overwriting $DBP. Report: $LIVE_CHECK"
    exit 2
  fi

  if ! sqlite3 -bail "$DB" ".backup '${TMP}'"; then
    logger -p user.err -t weewx-ram "sqlite .backup to $TMP failed"
    rm -f "$TMP"; exit 3
  fi

  BACKUP_CHECK=$(sqlite3 -bail "$TMP" 'PRAGMA integrity_check(1);' 2>&1 || true)
  if [[ "$BACKUP_CHECK" != "ok" ]]; then
    logger -p user.err -t weewx-ram \
      "BACKUP FILE failed integrity_check — discarding. Report: $BACKUP_CHECK"
    rm -f "$TMP"; exit 4
  fi

  for (( i=ROTATION_COUNT; i>=2; i-- )); do
    prev=$((i - 1))
    [[ -f "${DBP}.${prev}" ]] && mv -f "${DBP}.${prev}" "${DBP}.${i}"
  done
  [[ -f "$DBP" ]] && mv -f "$DBP" "${DBP}.1"
  mv -f "$TMP" "$DBP"
fi

rsync -aHAX --delete \
  --exclude='weewx.sdb' \
  --exclude='weewx.sdb-wal' \
  --exclude='weewx.sdb-shm' \
  --exclude='weewx.sdb-journal' \
  --exclude='weewx.sdb.tmp' \
  --exclude='weewx.sdb.[0-9]*' \
  "${MOUNT}/" "${PERSIST}/"

sync
logger -t weewx-ram "Saved $MOUNT to $PERSIST (rotation: keeping ${ROTATION_COUNT})"
SAVE_EOF

  # --- shutdown teardown: final save, umount, release zram -----------------
  sudo tee "$TEARDOWN_BIN" >/dev/null <<'TEARDOWN_EOF'
#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
source /etc/weewx-ramdisk.conf

/usr/local/sbin/weewx-ram-save || logger -t weewx-ram "save failed during teardown"

if mountpoint -q "$MOUNT"; then
  umount "$MOUNT" || umount -l "$MOUNT"
fi

if [[ -r /run/weewx-ram.dev ]]; then
  ZDEV=$(cat /run/weewx-ram.dev)
  [[ -b "$ZDEV" ]] && zramctl --reset "$ZDEV" 2>/dev/null || true
  rm -f /run/weewx-ram.dev
fi

logger -t weewx-ram "Teardown complete"
TEARDOWN_EOF

  sudo chmod 0755 "$SETUP_BIN" "$SAVE_BIN" "$TEARDOWN_BIN"
}

write_units() {
  log_info "Writing systemd units."
  sudo tee "$UNIT_MAIN" >/dev/null <<'EOF'
[Unit]
Description=WeeWX database on zram (restore on boot, save on shutdown)
After=local-fs.target
Before=weewx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/weewx-ram-setup
ExecStop=/usr/local/sbin/weewx-ram-teardown
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

  sudo tee "$UNIT_SAVE" >/dev/null <<'EOF'
[Unit]
Description=Snapshot WeeWX DB from zram to SD card
Requires=weewx-ramdisk.service
After=weewx-ramdisk.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/weewx-ram-save
EOF

  sudo tee "$TIMER_SAVE" >/dev/null <<'EOF'
[Unit]
Description=Periodic WeeWX DB snapshot to SD card

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Persistent=true
Unit=weewx-ramdisk-save.service

[Install]
WantedBy=timers.target
EOF

  sudo mkdir -p "$DROPIN_DIR"
  sudo tee "$DROPIN_FILE" >/dev/null <<'EOF'
[Unit]
Requires=weewx-ramdisk.service
After=weewx-ramdisk.service
EOF
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX"; then
    log_info "weewx-database-ram already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # --- DB-type self-skip --------------------------------------------------
  # weewx-database-ram is SQLite-specific (it manages the .sdb file on a
  # zram device with hourly validated snapshots). If feature-database
  # recorded a non-SQLite backend in /etc/installicious/state/database.state,
  # this feature has nothing meaningful to do. Mark complete and exit so
  # the user doesn't see a FAIL or end up with a half-built ramdisk.
  local _db_state="${PATH_STATE:-/etc/installicious/state}/database.state"
  if [[ -f $_db_state ]]; then
    local _db_type
    # shellcheck disable=SC1090
    _db_type=$(source "$_db_state" 2>/dev/null; printf '%s' "${DATABASE_TYPE:-}")
    case "$_db_type" in
      ""|sqlite)
        : # proceed normally
        ;;
      *)
        log_info "DATABASE_TYPE=$_db_type — weewx-database-ram is SQLite-only, skipping."
        status_mark_complete "$II_ID" "$II_VERSION"
        echo -e "[  \e[0;32mOK\e[0m  ] weewx-database-ram: not applicable for DATABASE_TYPE=$_db_type (skipped)."
        return 0
        ;;
    esac
  fi

  # Refuse to install on a system that doesn't have /var/lib/weewx yet —
  # weewx hasn't been set up, so there's nothing to migrate. The user
  # should install weewx (via the package or a manual run) first.
  if [[ ! -d $WEEWX_DB_DIR ]]; then
    log_fail "$WEEWX_DB_DIR does not exist; install weewx first."
    status_mark_failed "$II_ID" "no weewx dir"
    return 1
  fi

  # Apt deps that the runtime scripts (weewx-ram-setup, save, teardown)
  # call out to: sqlite3 (quick_check + .backup), rsync (non-DB mirror),
  # util-linux (zramctl), zram-tools (older zram-userland helpers some
  # distros keep around). Pre-install state recorded per-package so
  # --uninstall only removes what we put in place.
  log_info "Ensuring apt deps: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt deps install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install weewx-database-ram apt dependencies. Error Code: $rc."
    return $rc
  fi

  compute_ram_plan
  log_info "Plan: zram ${ZRAM_SIZE} ${ZRAM_ALGO} [${ZRAM_SIZE_SOURCE}] (model: ${DETECTED_PI_MODEL}, DB ${DETECTED_DB_MB}M, rotation ${WEEWX_DB_ROTATIONS})."

  # Stop weewx for the migration. Remember whether it was running so we
  # can restart it at the end.
  local weewx_was_active=false
  if systemctl is-active --quiet weewx 2>/dev/null; then
    weewx_was_active=true
    log_info "Stopping weewx for migration."
    sudo systemctl stop weewx || log_warn "systemctl stop weewx returned non-zero."
  fi

  # Persistent mirror on the SD card. Skip if we're already on a zram mount
  # (re-install case) — the mirror is authoritative in that scenario.
  sudo mkdir -p "$WEEWX_DB_HDD_DIR" \
    || { status_mark_failed "$II_ID" "mkdir $WEEWX_DB_HDD_DIR failed"; return 1; }
  if mountpoint -q "$WEEWX_DB_DIR"; then
    log_info "$WEEWX_DB_DIR is already a zram mount; skipping initial copy."
  elif [[ -d $WEEWX_DB_DIR ]]; then
    log_info "Mirroring $WEEWX_DB_DIR -> $WEEWX_DB_HDD_DIR."
    sudo rsync -aHAX --delete "${WEEWX_DB_DIR}/" "${WEEWX_DB_HDD_DIR}/" \
      || { status_mark_failed "$II_ID" "rsync to .hdd failed"; return 1; }
    local owner
    owner=$(stat -c %U:%G "$WEEWX_DB_DIR" 2>/dev/null || echo "weewx:weewx")
    sudo chown -R "$owner" "$WEEWX_DB_HDD_DIR" 2>/dev/null || true
  fi

  write_ramdisk_conf
  write_helpers
  write_units

  log_info "Enabling + starting units."
  sudo systemctl daemon-reload
  sudo systemctl enable weewx-ramdisk.service 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
    || log_warn "enable weewx-ramdisk returned non-zero."
  sudo systemctl enable --now weewx-ramdisk-save.timer 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
    || log_warn "enable timer returned non-zero."
  sudo systemctl start weewx-ramdisk.service 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
    || { status_mark_failed "$II_ID" "weewx-ramdisk.service failed to start"; return 1; }

  if [[ $weewx_was_active == "true" ]]; then
    log_info "Restarting weewx."
    sudo systemctl start weewx || log_warn "weewx restart returned non-zero."
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX"
  log_ok "weewx-database-ram installed."
  echo -e "[  \e[0;32mOK\e[0m  ] WeeWX DB is on zram (${ZRAM_SIZE} ${ZRAM_ALGO}); hourly + shutdown snapshots active."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "weewx-database-ram already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] weewx-database-ram is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record for weewx-database-ram; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  log_info "Stopping weewx + ramdisk timer/services."
  sudo systemctl stop weewx 2>/dev/null || true
  sudo systemctl disable --now weewx-ramdisk-save.timer 2>/dev/null || true
  sudo systemctl stop weewx-ramdisk.service 2>/dev/null || true
  sudo systemctl disable weewx-ramdisk.service 2>/dev/null || true

  log_info "Removing units + drop-in + helper scripts."
  sudo rm -f "$UNIT_MAIN" "$UNIT_SAVE" "$TIMER_SAVE" "$DROPIN_FILE"
  sudo rmdir "$DROPIN_DIR" 2>/dev/null || true
  sudo rm -f "$SETUP_BIN" "$SAVE_BIN" "$TEARDOWN_BIN"

  # Force-unmount the zram if it's still mounted (the teardown ExecStop
  # should have already done this when we stopped the service, but be
  # defensive in case it failed).
  if mountpoint -q "$WEEWX_DB_DIR"; then
    log_warn "$WEEWX_DB_DIR still mounted after stop; forcing umount."
    sudo umount "$WEEWX_DB_DIR" 2>/dev/null || sudo umount -l "$WEEWX_DB_DIR" 2>/dev/null || true
  fi

  # Restore from the SD-card mirror (this is the authoritative copy after
  # uninstall — the zram contents are gone). Falls back to leaving things
  # alone if the mirror doesn't exist.
  if [[ -d $WEEWX_DB_HDD_DIR ]]; then
    log_info "Restoring $WEEWX_DB_DIR from $WEEWX_DB_HDD_DIR."
    sudo mkdir -p "$WEEWX_DB_DIR"
    sudo rsync -aHAX --delete "${WEEWX_DB_HDD_DIR}/" "${WEEWX_DB_DIR}/" \
      || log_warn "rsync back to $WEEWX_DB_DIR returned non-zero."
    sudo chown -R weewx:weewx "$WEEWX_DB_DIR" 2>/dev/null || true
    log_info "Removing $WEEWX_DB_HDD_DIR (mirror no longer needed)."
    sudo rm -rf "$WEEWX_DB_HDD_DIR"
  fi

  # Restore /etc/weewx-ramdisk.conf from snapshot if we replaced an existing
  # one; otherwise just remove the file we wrote.
  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $RAMDISK_CONF from snapshot."
    backup_restore_or_remove "$II_ID" "$RAMDISK_CONF" || log_warn "restore returned non-zero."
  else
    sudo rm -f "$RAMDISK_CONF"
  fi

  sudo systemctl daemon-reload

  # Restart weewx now that everything's reverted.
  if systemctl is-enabled --quiet weewx 2>/dev/null; then
    sudo systemctl start weewx || log_warn "weewx restart returned non-zero."
  fi

  # Revert apt packages we installed (per-package pre-state check leaves
  # anything that was already there — e.g. rsync is almost always present
  # on a Pi independent of this feature).
  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "weewx-database-ram uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] weewx-database-ram uninstalled (DB restored from SD-card mirror)."
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
