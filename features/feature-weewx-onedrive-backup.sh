#!/bin/bash

# Module:      WeeWX database backup to OneDrive
# Description: Installs daily / weekly / monthly off-site backups of the
#              WeeWX SQLite database to OneDrive, driven by rclone + systemd
#              timers. Each run takes a consistent snapshot of the database
#              with the SQLite online-backup API, verifies it, compresses it
#              with zstd (level auto-tuned per Pi model), uploads it to a
#              tier-specific OneDrive folder, then prunes that folder to its
#              configured keep-count.
#
#              DISK, never RAM. The backup always reads a disk-resident copy
#              of the database, never the volatile zram device:
#                - If the weewx-database-ram feature is installed
#                  (/etc/weewx-ramdisk.conf present), the runtime script
#                  triggers a fresh weewx-ram-save to flush RAM->disk, then
#                  backs up the SD-card mirror ($PERSIST).
#                - Otherwise WeeWX writes the DB straight to disk and the
#                  runtime script backs that up directly.
#              The detection is per RUN, so installing or removing
#              weewx-database-ram later is picked up automatically — this
#              feature does NOT depend on it.
#
#              The database file is WEEWX_BACKUP_DB_PATH (default
#              /var/lib/weewx/weewx.sdb), so a future WeeWX-database option
#              that renames or relocates the SQLite file only needs that one
#              key updated. (A non-SQLite backend — MySQL/MariaDB — would
#              need a different backup path entirely; out of scope today.)
#
#              Snapshot verification level is WEEWX_BACKUP_VERIFY:
#              "integrity" (default — full PRAGMA integrity_check), "quick"
#              (PRAGMA quick_check — much faster, still catches most
#              corruption), or "off". It runs on the snapshot — the exact
#              bytes about to be uploaded — under the nightly idle-priority
#              timer (30-min budget), so even a full check is not a concern.
#
#              On install:
#                1. Installs apt deps (rclone, zstd, sqlite3). Pre-install
#                   state is recorded per package so --uninstall only
#                   removes packages we put in place.
#                2. Verifies the rclone config (WEEWX_BACKUP_RCLONE_CONF)
#                   exists and its OneDrive remote is reachable. rclone is
#                   configured on a desktop machine and the resulting
#                   rclone.conf copied to the Pi — see
#                   scripts/weewx-onedrive-setup.md. The install FAILS with
#                   a clear message if the config or remote is missing;
#                   it never tries to run an interactive rclone OAuth flow.
#                3. Walks + creates the OneDrive folder tree (idempotent).
#                4. Writes /etc/weewx-onedrive-backup.conf (single source of
#                   truth for the runtime script), installs the runtime
#                   backup script in /usr/local/sbin/, and installs three
#                   systemd service + timer pairs (chained with After= so
#                   they never run concurrently).
#
#              Retention is COUNT-based and configurable: after each upload
#              the tier folder is pruned to its newest N files
#              (WEEWX_BACKUP_KEEP_DAILY / _WEEKLY / _MONTHLY — defaults
#              7 / 8 / 12). The tier filenames are zero-padded date stamps,
#              so a lexical sort is a chronological sort.
#
#              II_DEPS="weewx": only the weewx package is required — there
#              must be a database to back up. weewx-database-ram is NOT a
#              dependency; see the DISK/RAM note above.
#
#              --uninstall reverses in opposite order: stops + disables the
#              timers, removes the units / runtime script / runtime config,
#              then reverts the apt packages. It deliberately leaves the
#              rclone config AND any already-uploaded OneDrive backups
#              untouched — deleting cloud data is opt-in (see the uninstall
#              section of scripts/weewx-onedrive-setup.md).

# === II_MANIFEST_BEGIN ===
II_ID="weewx-onedrive-backup"
II_TITLE="WeeWX database backup to OneDrive"
II_CATEGORY="feature"
II_VERSION="2"
II_DEPS="weewx"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_APT_PACKAGES="rclone zstd sqlite3"
II_EDITABLE_CONFIG="WEEWX_BACKUP_RCLONE_CONF WEEWX_BACKUP_DB_PATH WEEWX_BACKUP_KEEP_DAILY WEEWX_BACKUP_KEEP_WEEKLY WEEWX_BACKUP_KEEP_MONTHLY"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/installer_apt.sh
source lib/verify.sh

FILE_CONFIG_ONEDRIVE="${PATH_CONFIG:-config}/weewx-onedrive-backup.config"
[[ -f $FILE_CONFIG_ONEDRIVE ]] && source "$FILE_CONFIG_ONEDRIVE"
state_apply_menu_overrides
WEEWX_BACKUP_RCLONE_CONF="${WEEWX_BACKUP_RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
WEEWX_BACKUP_DB_PATH="${WEEWX_BACKUP_DB_PATH:-/var/lib/weewx/weewx.sdb}"
WEEWX_BACKUP_KEEP_DAILY="${WEEWX_BACKUP_KEEP_DAILY:-7}"
WEEWX_BACKUP_KEEP_WEEKLY="${WEEWX_BACKUP_KEEP_WEEKLY:-8}"
WEEWX_BACKUP_KEEP_MONTHLY="${WEEWX_BACKUP_KEEP_MONTHLY:-12}"
WEEWX_BACKUP_VERIFY="${WEEWX_BACKUP_VERIFY:-integrity}"
WEEWX_BACKUP_REMOTE_NAME="${WEEWX_BACKUP_REMOTE_NAME:-onedrive}"
WEEWX_BACKUP_REMOTE_ROOT="${WEEWX_BACKUP_REMOTE_ROOT:-Documents-Private/Backups/WeeWX/Database}"

RAMDISK_CONF="/etc/weewx-ramdisk.conf"
BACKUP_CONF="/etc/weewx-onedrive-backup.conf"
BACKUP_BIN="/usr/local/sbin/weewx-onedrive-backup"
TIERS=(daily weekly monthly)

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

# _sanitize_counts — clamp the three WEEWX_BACKUP_KEEP_* globals to positive
# integers, reassigning the documented default for any that aren't (and
# warning). A keep-count of 0 is rejected — it would delete the file we just
# uploaded. Reassigns in place; the ^[1-9][0-9]*$ test rejects 0, empties,
# leading zeros, and non-numerics without touching (( )) arithmetic.
_sanitize_counts() {
  local pair name fallback cur
  for pair in "WEEWX_BACKUP_KEEP_DAILY:7" \
              "WEEWX_BACKUP_KEEP_WEEKLY:8" \
              "WEEWX_BACKUP_KEEP_MONTHLY:12"; do
    name="${pair%:*}"
    fallback="${pair#*:}"
    cur="${!name}"
    if [[ ! $cur =~ ^[1-9][0-9]*$ ]]; then
      log_warn "$name='$cur' is not a positive integer; falling back to $fallback."
      printf -v "$name" '%s' "$fallback"
    fi
  done
}

# ensure_remote_tree — walk WEEWX_BACKUP_REMOTE_ROOT one path segment at a
# time creating any that don't exist, then create the three tier subfolders.
# Idempotent: shows [exists] vs [create] so a typo in the root surfaces
# before any upload. rc=1 if a mkdir fails.
ensure_remote_tree() {
  local conf="$1" remote="$2" root="$3"
  local -a parts walk=()
  local accum="" part parent leaf dir

  IFS='/' read -ra parts <<< "$root"
  for part in "${parts[@]}"; do
    accum="${accum:+${accum}/}${part}"
    walk+=("$accum")
  done
  for part in "${TIERS[@]}"; do
    walk+=("${root}/${part}")
  done

  for dir in "${walk[@]}"; do
    if [[ $dir == */* ]]; then parent="${dir%/*}"; else parent=""; fi
    leaf="${dir##*/}"
    if rclone --config "$conf" lsf --dirs-only "${remote}:${parent}" 2>/dev/null \
       | grep -qx "${leaf}/"; then
      log_info "OneDrive folder exists: ${remote}:${dir}"
    else
      log_info "Creating OneDrive folder: ${remote}:${dir}"
      # Capture rclone's own exit + output directly — piping into `tee`
      # would mask the failure behind tee's (almost always 0) exit status.
      local mkout
      if ! mkout=$(rclone --config "$conf" mkdir "${remote}:${dir}" 2>&1); then
        [[ -n $mkout ]] && log_warn "rclone mkdir: $mkout"
        log_fail "Failed to create OneDrive folder ${remote}:${dir}."
        return 1
      fi
    fi
  done
  return 0
}

write_runtime_conf() {
  log_info "Writing $BACKUP_CONF (remote ${WEEWX_BACKUP_REMOTE_NAME}:${WEEWX_BACKUP_REMOTE_ROOT}, keep ${WEEWX_BACKUP_KEEP_DAILY}/${WEEWX_BACKUP_KEEP_WEEKLY}/${WEEWX_BACKUP_KEEP_MONTHLY}, verify ${WEEWX_BACKUP_VERIFY})."
  sudo tee "$BACKUP_CONF" >/dev/null <<CONF
# /etc/weewx-onedrive-backup.conf
# Generated by feature-weewx-onedrive-backup.sh — re-run installicious to
# refresh. Sourced by the runtime backup script so the layout + retention
# live in exactly one place. Edit the WEEWX_BACKUP_* keys via installicious
# (config/weewx-onedrive-backup.config, the in-menu editor, or
# overrides/configuration.override), not here.
REMOTE_NAME="${WEEWX_BACKUP_REMOTE_NAME}"
REMOTE_ROOT="${WEEWX_BACKUP_REMOTE_ROOT}"
CONF_FILE="${WEEWX_BACKUP_RCLONE_CONF}"
DB_PATH="${WEEWX_BACKUP_DB_PATH}"
VERIFY="${WEEWX_BACKUP_VERIFY}"
KEEP_DAILY="${WEEWX_BACKUP_KEEP_DAILY}"
KEEP_WEEKLY="${WEEWX_BACKUP_KEEP_WEEKLY}"
KEEP_MONTHLY="${WEEWX_BACKUP_KEEP_MONTHLY}"
CONF
  sudo chmod 0644 "$BACKUP_CONF"
}

write_backup_bin() {
  log_info "Writing runtime backup script $BACKUP_BIN."
  sudo install -d /usr/local/sbin
  sudo tee "$BACKUP_BIN" >/dev/null <<'ONEDRIVE_BACKUP_EOF'
#!/bin/bash
# /usr/local/sbin/weewx-onedrive-backup
# Snapshot + verify + compress + upload the WeeWX database to OneDrive,
# then prune the tier folder to its configured keep-count. Called by
# systemd timers. Usage: weewx-onedrive-backup {daily|weekly|monthly}
set -euo pipefail

# shellcheck disable=SC1091
source /etc/weewx-onedrive-backup.conf

TIER="${1:-daily}"
case "$TIER" in
  daily)    KEEP="${KEEP_DAILY:-7}"    ;;
  weekly)   KEEP="${KEEP_WEEKLY:-8}"   ;;
  monthly)  KEEP="${KEEP_MONTHLY:-12}" ;;
  *) echo "Usage: $0 {daily|weekly|monthly}" >&2; exit 2 ;;
esac

# Per-run DB-type self-skip: this script reads SQLite files via
# `sqlite3 .backup`. If the WeeWX backend is mysql/mariadb (per
# feature-database), there's nothing for us to do here today (a
# mysqldump branch is a planned follow-up).
if [[ -f /etc/installicious/state/database.state ]]; then
  # shellcheck disable=SC1091
  source /etc/installicious/state/database.state
  case "${DATABASE_TYPE:-sqlite}" in
    ""|sqlite) : ;;
    *)
      logger -t weewx-onedrive "[$TIER] DATABASE_TYPE=$DATABASE_TYPE -- SQLite-only backup, skipping."
      exit 0 ;;
  esac
fi

REMOTE_PATH="${REMOTE_ROOT}/${TIER}"
DB_PATH="${DB_PATH:-/var/lib/weewx/weewx.sdb}"
DB_FILE="${DB_PATH##*/}"

# --- 1. Resolve a DISK-resident copy of the database -------------------
# Never the volatile zram device. If the weewx-database-ram feature is
# installed, flush RAM->disk first and back up the SD-card mirror;
# otherwise WeeWX writes the DB straight to disk and we back that up. The
# check is per run, so adding/removing weewx-database-ram is picked up
# automatically.
if [[ -f /etc/weewx-ramdisk.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/weewx-ramdisk.conf
  logger -t weewx-onedrive \
    "[$TIER] zram database detected — flushing RAM->disk via weewx-ram-save"
  if ! /usr/local/sbin/weewx-ram-save; then
    logger -p user.warning -t weewx-onedrive \
      "[$TIER] weewx-ram-save returned non-zero — backing up the current SD-card mirror"
  fi
  DB_SRC="${PERSIST}/${DB_FILE}"
else
  DB_SRC="$DB_PATH"
  logger -t weewx-onedrive "[$TIER] No zram database — backing up on-disk DB $DB_SRC"
fi

if [[ ! -f "$DB_SRC" ]]; then
  logger -p user.err -t weewx-onedrive "[$TIER] No database at $DB_SRC — aborting"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- 2. Consistent snapshot via the SQLite online-backup API -----------
# `sqlite3 .backup` is safe even while WeeWX is mid-write, so this is
# correct whether DB_SRC is the (static) SD-card mirror or the live
# on-disk DB. It also fails loudly if DB_SRC is not a readable SQLite
# database at all.
SNAP="${TMPDIR}/${DB_FILE}"
logger -t weewx-onedrive "[$TIER] Snapshotting $DB_SRC via sqlite .backup"
if ! SNAP_ERR=$(sqlite3 -bail "$DB_SRC" ".backup '${SNAP}'" 2>&1); then
  logger -p user.err -t weewx-onedrive \
    "[$TIER] sqlite .backup of $DB_SRC FAILED — aborting${SNAP_ERR:+: $SNAP_ERR}"
  exit 3
fi

# --- 3. Verify the snapshot — the exact bytes we're about to upload ----
# VERIFY: integrity (full PRAGMA integrity_check, default) | quick
# (PRAGMA quick_check — faster) | off. quick_check(1) / integrity_check(1)
# both cap the report at the first error.
case "${VERIFY:-integrity}" in
  off)
    logger -t weewx-onedrive "[$TIER] Snapshot verification disabled (VERIFY=off)"
    ;;
  quick)
    SCHECK=$(sqlite3 -bail "$SNAP" 'PRAGMA quick_check(1);' 2>&1 || true)
    if [[ "$SCHECK" != "ok" ]]; then
      logger -p user.err -t weewx-onedrive \
        "[$TIER] quick_check FAILED on the snapshot — refusing to upload. Report: $SCHECK"
      exit 3
    fi
    logger -t weewx-onedrive "[$TIER] Snapshot passed quick_check"
    ;;
  *)
    SCHECK=$(sqlite3 -bail "$SNAP" 'PRAGMA integrity_check(1);' 2>&1 || true)
    if [[ "$SCHECK" != "ok" ]]; then
      logger -p user.err -t weewx-onedrive \
        "[$TIER] integrity_check FAILED on the snapshot — refusing to upload. Report: $SCHECK"
      exit 3
    fi
    logger -t weewx-onedrive "[$TIER] Snapshot passed integrity_check"
    ;;
esac

# --- 4. Compose tier-appropriate filename ------------------------------
# Stamps are zero-padded so a lexical sort of a tier folder is a
# chronological sort — the prune step relies on this. The upload name is
# fixed as weewx-<stamp>.sdb.zst regardless of the source DB filename, so
# the prune glob keeps matching if WEEWX_BACKUP_DB_PATH is ever renamed.
case "$TIER" in
  daily)    STAMP=$(date +%Y-%m-%d) ;;
  weekly)   STAMP=$(date +%G-W%V)   ;;   # ISO year-week, e.g. 2026-W21
  monthly)  STAMP=$(date +%Y-%m)    ;;
esac
NAME="weewx-${STAMP}.sdb.zst"

# --- Auto-tune zstd level + threads based on hardware -----------------
# Level 19 is ~15 min on a Pi 3, ~2 min on a Pi 4, <1 min on a Pi 5. We
# pick a level that keeps each run to a few minutes on the device while
# still compressing well. Override either value at runtime, e.g.:
#   sudo ZSTD_LEVEL=3 systemctl start weewx-onedrive-backup-daily.service
detect_zstd_params() {
  local level="${ZSTD_LEVEL:-}"
  local threads="${ZSTD_THREADS:-}"
  local model=""

  if [[ -r /proc/device-tree/model ]]; then
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
  fi
  if [[ -z "$model" && -r /proc/cpuinfo ]]; then
    model=$(awk -F: '/^Model/{sub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
  fi

  local nproc_count
  nproc_count=$(nproc 2>/dev/null || echo 1)

  if [[ -z "$level" ]]; then
    case "$model" in
      *"Pi 5"*)       level=19 ;;
      *"Pi 4"*)       level=15 ;;
      *"Pi Zero 2"*)  level=6  ;;   # A53 but thermally throttled
      *"Pi 3"*)       level=9  ;;
      *"Pi 2"*)       level=6  ;;
      *"Pi Zero"*)    level=3  ;;   # original Zero / Zero W, single core
      *"Pi "*)        level=9  ;;   # any unknown Pi — safe middle
      *)              level=19 ;;   # not a Pi at all: laptop / x86 server
    esac
  fi

  if [[ -z "$threads" ]]; then
    threads="$nproc_count"
  fi

  echo "${level} ${threads} ${model:-unknown}"
}

read -r ZLEVEL ZTHREADS ZMODEL <<< "$(detect_zstd_params)"
logger -t weewx-onedrive \
  "[$TIER] Compressing with zstd -${ZLEVEL} -T${ZTHREADS} (detected: ${ZMODEL})"

zstd -q "-${ZLEVEL}" "-T${ZTHREADS}" -o "${TMPDIR}/${NAME}" "$SNAP"
SIZE=$(stat -c%s "${TMPDIR}/${NAME}")

# --- 5. Upload ---------------------------------------------------------
logger -t weewx-onedrive "[$TIER] Uploading $NAME (${SIZE} bytes) to ${REMOTE_PATH}/"
if ! rclone copy "${TMPDIR}/${NAME}" "${REMOTE_NAME}:${REMOTE_PATH}/" \
      --config "$CONF_FILE" \
      --stats 0 --transfers 1 --retries 3 --low-level-retries 10; then
  logger -p user.err -t weewx-onedrive "[$TIER] Upload of $NAME FAILED"
  exit 4
fi
logger -t weewx-onedrive "[$TIER] Upload complete: $NAME"

# --- 6. Prune the tier to its newest $KEEP files -----------------------
# List this tier's backup files, sort lexically (= chronologically, since
# the stamps are zero-padded), and delete everything but the newest $KEEP.
if [[ "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
  mapfile -t EXISTING < <(rclone lsf --files-only --include 'weewx-*.sdb.zst' \
    "${REMOTE_NAME}:${REMOTE_PATH}/" --config "$CONF_FILE" 2>/dev/null | sort)
  COUNT=${#EXISTING[@]}
  if (( COUNT > KEEP )); then
    PRUNE=$(( COUNT - KEEP ))
    logger -t weewx-onedrive \
      "[$TIER] Pruning $PRUNE of $COUNT file(s) — keeping newest $KEEP"
    for (( i=0; i<PRUNE; i++ )); do
      if rclone deletefile "${REMOTE_NAME}:${REMOTE_PATH}/${EXISTING[i]}" \
           --config "$CONF_FILE" --stats 0; then
        logger -t weewx-onedrive "[$TIER] Pruned ${EXISTING[i]}"
      else
        logger -p user.warning -t weewx-onedrive \
          "[$TIER] Failed to prune ${EXISTING[i]} (not fatal)"
      fi
    done
  else
    logger -t weewx-onedrive \
      "[$TIER] $COUNT file(s) within keep-count $KEEP — nothing to prune"
  fi
else
  logger -p user.warning -t weewx-onedrive \
    "[$TIER] keep-count '$KEEP' is not a positive integer — skipping prune"
fi
ONEDRIVE_BACKUP_EOF
  sudo chmod 0755 "$BACKUP_BIN"
}

write_units() {
  log_info "Writing systemd service + timer units."

  # Schedule spacing: daily 02:30, weekly Sun 03:30, monthly 1st 04:30.
  # With RandomizedDelaySec=10min the closest two runs can ever get is ~50
  # min; each service also declares After= the previous tier so on the one
  # day a month all three fire, systemd queues them serially rather than
  # racing them (concurrent weewx-ram-save writes to the same DB would be
  # bad).
  local tier after_units desc oncalendar
  for tier in "${TIERS[@]}"; do
    case "$tier" in
      daily)
        desc="daily"
        oncalendar="*-*-* 02:30:00"
        after_units="network-online.target weewx-ramdisk.service"
        ;;
      weekly)
        desc="weekly"
        oncalendar="Sun 03:30:00"
        after_units="network-online.target weewx-ramdisk.service weewx-onedrive-backup-daily.service"
        ;;
      monthly)
        desc="monthly"
        oncalendar="*-*-01 04:30:00"
        after_units="network-online.target weewx-ramdisk.service weewx-onedrive-backup-daily.service weewx-onedrive-backup-weekly.service"
        ;;
    esac

    sudo tee "/etc/systemd/system/weewx-onedrive-backup-${tier}.service" >/dev/null <<SERVICE
[Unit]
Description=WeeWX ${desc} database backup to OneDrive
After=${after_units}
Wants=network-online.target
ConditionPathExists=${BACKUP_CONF}

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=${BACKUP_BIN} ${tier}
# Don't let a stuck upload wedge the timer forever.
TimeoutStartSec=30min
SERVICE

    sudo tee "/etc/systemd/system/weewx-onedrive-backup-${tier}.timer" >/dev/null <<TIMER
[Unit]
Description=WeeWX ${desc} database backup to OneDrive

[Timer]
OnCalendar=${oncalendar}
Persistent=true
RandomizedDelaySec=10min
Unit=weewx-onedrive-backup-${tier}.service

[Install]
WantedBy=timers.target
TIMER
  done
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_ONEDRIVE"; then
    log_info "weewx-onedrive-backup already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # --- DB-type self-skip --------------------------------------------------
  # weewx-onedrive-backup uses sqlite3 .backup to make a consistent
  # snapshot of the WeeWX SQLite file. If feature-database recorded a
  # non-SQLite backend, this feature has nothing to do today (a mysqldump
  # branch is a planned follow-up). Mark complete and exit cleanly.
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
        log_info "DATABASE_TYPE=$_db_type — weewx-onedrive-backup is SQLite-only, skipping."
        status_mark_complete "$II_ID" "$II_VERSION"
        echo -e "[  \e[0;32mOK\e[0m  ] weewx-onedrive-backup: not applicable for DATABASE_TYPE=$_db_type (skipped)."
        return 0
        ;;
    esac
  fi

  _sanitize_counts

  # Which database source will the runtime script use? Informational only —
  # the script re-checks per run, so installing or removing
  # weewx-database-ram later is picked up with no re-install needed.
  if [[ -f $RAMDISK_CONF ]]; then
    log_info "weewx-database-ram detected — backups will flush RAM->disk and use the SD-card DB mirror."
  else
    log_info "No weewx-database-ram — backups will use the on-disk database at $WEEWX_BACKUP_DB_PATH."
  fi

  # Apt deps the runtime script calls out to: rclone (transfer), zstd
  # (compress), sqlite3 (.backup snapshot + verify). Per-package pre-state
  # is recorded so --uninstall only removes packages we put in place.
  log_info "Ensuring apt deps: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt deps install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install weewx-onedrive-backup apt dependencies. Error Code: $rc."
    return $rc
  fi

  # The rclone config is authored on a desktop machine and copied to the Pi
  # (scripts/weewx-onedrive-setup.md). This feature never runs an interactive
  # OAuth flow — it fails fast and tells the user to place the file.
  if [[ ! -f $WEEWX_BACKUP_RCLONE_CONF ]]; then
    log_fail "rclone config not found at $WEEWX_BACKUP_RCLONE_CONF."
    status_mark_failed "$II_ID" "rclone.conf missing at $WEEWX_BACKUP_RCLONE_CONF"
    echo -e "[ \e[0;31mFAIL\e[0m ] No rclone config at $WEEWX_BACKUP_RCLONE_CONF — configure rclone on a desktop and copy rclone.conf there (see scripts/weewx-onedrive-setup.md), or set WEEWX_BACKUP_RCLONE_CONF."
    return 1
  fi

  if ! rclone --config "$WEEWX_BACKUP_RCLONE_CONF" listremotes 2>/dev/null \
       | grep -qx "${WEEWX_BACKUP_REMOTE_NAME}:"; then
    log_fail "rclone remote '${WEEWX_BACKUP_REMOTE_NAME}:' is not defined in $WEEWX_BACKUP_RCLONE_CONF."
    status_mark_failed "$II_ID" "remote ${WEEWX_BACKUP_REMOTE_NAME} not configured"
    echo -e "[ \e[0;31mFAIL\e[0m ] rclone config has no '${WEEWX_BACKUP_REMOTE_NAME}:' remote — check WEEWX_BACKUP_REMOTE_NAME or re-create rclone.conf (see scripts/weewx-onedrive-setup.md)."
    return 1
  fi

  # Connectivity smoke test — listing the remote root proves the OAuth
  # token still works before we wire up timers that would only fail later.
  log_info "Verifying OneDrive remote '${WEEWX_BACKUP_REMOTE_NAME}:' is reachable."
  if ! rclone --config "$WEEWX_BACKUP_RCLONE_CONF" lsd "${WEEWX_BACKUP_REMOTE_NAME}:" >/dev/null 2>&1; then
    log_fail "Could not list '${WEEWX_BACKUP_REMOTE_NAME}:' — auth or network problem."
    status_mark_failed "$II_ID" "remote ${WEEWX_BACKUP_REMOTE_NAME} unreachable"
    echo -e "[ \e[0;31mFAIL\e[0m ] Could not reach OneDrive remote '${WEEWX_BACKUP_REMOTE_NAME}:' — check the network, or reconnect with: sudo rclone --config $WEEWX_BACKUP_RCLONE_CONF config reconnect ${WEEWX_BACKUP_REMOTE_NAME}:"
    return 1
  fi

  log_info "Verifying OneDrive folder tree under ${WEEWX_BACKUP_REMOTE_NAME}:${WEEWX_BACKUP_REMOTE_ROOT}/."
  if ! ensure_remote_tree "$WEEWX_BACKUP_RCLONE_CONF" "$WEEWX_BACKUP_REMOTE_NAME" "$WEEWX_BACKUP_REMOTE_ROOT"; then
    status_mark_failed "$II_ID" "OneDrive folder tree creation failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not create the OneDrive backup folder tree."
    return 1
  fi

  write_runtime_conf
  write_backup_bin
  write_units

  log_info "Enabling + starting backup timers."
  sudo systemctl daemon-reload
  local tier
  for tier in "${TIERS[@]}"; do
    sudo systemctl enable --now "weewx-onedrive-backup-${tier}.timer" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
      || log_warn "enable weewx-onedrive-backup-${tier}.timer returned non-zero."
  done

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_ONEDRIVE"
  log_ok "weewx-onedrive-backup installed (keep ${WEEWX_BACKUP_KEEP_DAILY}/${WEEWX_BACKUP_KEEP_WEEKLY}/${WEEWX_BACKUP_KEEP_MONTHLY})."
  echo -e "[  \e[0;32mOK\e[0m  ] WeeWX DB backups to OneDrive scheduled (daily/weekly/monthly timers active)."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "weewx-onedrive-backup already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] weewx-onedrive-backup is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record for weewx-onedrive-backup; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  log_info "Stopping + disabling backup timers and services."
  local tier
  for tier in "${TIERS[@]}"; do
    sudo systemctl disable --now "weewx-onedrive-backup-${tier}.timer" 2>/dev/null || true
    sudo systemctl stop "weewx-onedrive-backup-${tier}.service" 2>/dev/null || true
  done

  log_info "Removing units, runtime script, and runtime config."
  for tier in "${TIERS[@]}"; do
    sudo rm -f "/etc/systemd/system/weewx-onedrive-backup-${tier}.service" \
               "/etc/systemd/system/weewx-onedrive-backup-${tier}.timer"
  done
  sudo systemctl daemon-reload
  sudo systemctl reset-failed 'weewx-onedrive-backup-*' 2>/dev/null || true
  sudo rm -f "$BACKUP_BIN" "$BACKUP_CONF"

  # The rclone config and any already-uploaded OneDrive backups are left
  # untouched on purpose — deleting cloud data is opt-in (see the uninstall
  # section of scripts/weewx-onedrive-setup.md).
  log_info "Leaving $WEEWX_BACKUP_RCLONE_CONF and existing OneDrive backups in place (delete manually if decommissioning)."

  # Revert apt packages we installed (per-package pre-state check leaves
  # anything that was already there).
  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "weewx-onedrive-backup uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] weewx-onedrive-backup uninstalled (OneDrive backups left intact)."
  return 0
}

do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  # Self-skip respects DATABASE_TYPE (mirrors do_install).
  local _db_state="${PATH_STATE:-/etc/installicious/state}/database.state"
  if [[ -f $_db_state ]]; then
    local _db_type
    _db_type=$(source "$_db_state" 2>/dev/null; printf '%s' "${DATABASE_TYPE:-}")
    case "$_db_type" in
      ""|sqlite) : ;;
      *) echo "DATABASE_TYPE=$_db_type — SQLite-only, not applicable"; return 0 ;;
    esac
  fi

  local rc=0 err tier
  for tier in daily weekly monthly; do
    if ! err=$(verify_systemd_active "weewx-onedrive-backup-${tier}.timer" 2>&1); then echo "$err"; rc=1; fi
  done
  if ! err=$(verify_file_exists /usr/local/sbin/weewx-onedrive-backup 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_file_exists /etc/weewx-onedrive-backup.conf 2>&1); then echo "$err"; rc=1; fi
  return $rc
}

if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "verify" ]]; then
  do_verify
else
  do_uninstall
fi
exit $?
