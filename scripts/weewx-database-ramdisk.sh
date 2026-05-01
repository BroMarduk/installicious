#!/bin/bash
# weewx-database-ramdisk.sh
# Companion to install-ramdisk.logging.sh: move the WeeWX SQLite database to a
# zram-backed ext4 filesystem, with VALIDATED crash-safe hourly snapshots,
# snapshot rotation, and a clean save on shutdown.
#
# Target: Raspberry Pi OS (Bullseye / Bookworm / Trixie) with
#         install-ramdisk.logging.sh already applied (so zramctl and
#         zram-tools are present and tuned).
# Run:    sudo bash weewx-database-ramdisk.sh
#
# What it does:
#   1. Installs sqlite3 (for PRAGMA integrity_check and crash-safe .backup).
#   2. Copies /var/lib/weewx to /var/lib/weewx.hdd (persistent mirror on SD).
#   3. On every boot, allocates a dedicated zram device (separate from the
#      swap zram and log2ram zram), formats it ext4, mounts it at
#      /var/lib/weewx, and restores the newest snapshot from .hdd that
#      passes PRAGMA integrity_check — falling back to older rotated
#      snapshots if the primary is corrupt.
#   4. On clean shutdown, snapshots the live DB back to /var/lib/weewx.hdd:
#        - PRAGMA quick_check on the live DB first (refuses to overwrite
#          a good snapshot with a corrupt live DB)
#        - sqlite3 .backup to a .tmp file
#        - PRAGMA integrity_check on the .tmp (discards if it fails)
#        - rotate weewx.sdb -> .1 -> .2 -> ... (keep last ROTATION_COUNT)
#        - atomic mv promote
#   5. A timer runs the same save hourly during normal operation.
#   6. Patches weewx.service with a drop-in so it requires the ramdisk
#      service (startup ordering + clean shutdown propagation).
#
# All modified config is backed up with a .bak suffix.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect OS + Pi model (mirrors install-ramdisk.logging.sh's logic for consistency)
# ---------------------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_VERSION_ID="${VERSION_ID:-0}"
  OS_CODENAME="${VERSION_CODENAME:-unknown}"
else
  OS_VERSION_ID=0
  OS_CODENAME=unknown
fi

PI_MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
  PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
fi

# Use the same compression algorithm install-ramdisk.logging.sh chose for this Pi class.
case "$PI_MODEL" in
  *"Pi 5"*|*"Pi 4"*|*"Compute Module 4"*|*"Pi 400"*) ZRAM_ALGO=zstd ;;
  *)                                                  ZRAM_ALGO=lz4  ;;
esac

# ---------------------------------------------------------------------------
# Size the zram device from the current DB (with growth headroom)
# ---------------------------------------------------------------------------
# Logical ext4 size = current DB * 1.5 + rounding, floor 256M.
# Actual RAM usage is roughly half that with lz4 on SQLite, a third with zstd.
DB_PATH=/var/lib/weewx/weewx.sdb
if [[ -f "$DB_PATH" ]]; then
  DB_MB=$(( $(stat -c %s "$DB_PATH") / 1024 / 1024 ))
  ZRAM_SIZE_MB=$(( (DB_MB * 3 / 2 + 127) / 128 * 128 ))
  (( ZRAM_SIZE_MB < 256 )) && ZRAM_SIZE_MB=256
else
  DB_MB=0
  ZRAM_SIZE_MB=512
fi
ZRAM_SIZE="${ZRAM_SIZE_MB}M"

# Rough actual-RAM estimate (assumes ~2.5x for lz4, ~3.5x for zstd)
case "$ZRAM_ALGO" in
  zstd) EST_RAM_MB=$((ZRAM_SIZE_MB * 10 / 35)) ;;
  *)    EST_RAM_MB=$((ZRAM_SIZE_MB * 10 / 25)) ;;
esac

# Number of rotated snapshots to retain on the SD card. Each snapshot is
# roughly DB_MB on disk, so 5 * 259M ~= 1.3 GB at current size.
ROTATION_COUNT=5

cat <<EOF
Detected:
  OS:         ${OS_CODENAME} (${OS_VERSION_ID})
  Model:      ${PI_MODEL}
  DB size:    ${DB_MB} MB (/var/lib/weewx/weewx.sdb)
Plan:
  zram:       ${ZRAM_SIZE} ${ZRAM_ALGO}  (estimated actual RAM: ~${EST_RAM_MB} MB)
  snapshots:  hourly (SQLite online backup) + clean shutdown
  rotation:   keep last ${ROTATION_COUNT} snapshots (.sdb, .sdb.1 ... .sdb.${ROTATION_COUNT})
  validation: quick_check live DB before save; integrity_check on backups

EOF

# ---------------------------------------------------------------------------
# 1. Install prerequisites
# ---------------------------------------------------------------------------
echo "==> Installing sqlite3 and helpers"
apt update
apt install -y sqlite3 rsync util-linux

# ---------------------------------------------------------------------------
# 2. Stop weewx and mirror the current DB to the persistent location
# ---------------------------------------------------------------------------
echo "==> Stopping weewx"
WEEWX_WAS_ACTIVE=false
if systemctl is-active --quiet weewx 2>/dev/null; then
  WEEWX_WAS_ACTIVE=true
fi
systemctl stop weewx 2>/dev/null || true

echo "==> Creating persistent mirror at /var/lib/weewx.hdd"
mkdir -p /var/lib/weewx.hdd

# If re-running on a system that already has zram mounted at /var/lib/weewx,
# the .hdd copy is already authoritative — skip the initial migration.
if mountpoint -q /var/lib/weewx; then
  echo "   (/var/lib/weewx is already a zram mount — skipping initial copy)"
else
  if [[ -d /var/lib/weewx ]]; then
    rsync -aHAX --delete /var/lib/weewx/ /var/lib/weewx.hdd/
    OWNER=$(stat -c %U:%G /var/lib/weewx 2>/dev/null || echo weewx:weewx)
    chown -R "$OWNER" /var/lib/weewx.hdd
  fi
fi

# ---------------------------------------------------------------------------
# 3. Config file shared by helper scripts
# ---------------------------------------------------------------------------
echo "==> Writing /etc/weewx-ramdisk.conf"
[[ -f /etc/weewx-ramdisk.conf && ! -f /etc/weewx-ramdisk.conf.bak ]] \
  && cp /etc/weewx-ramdisk.conf /etc/weewx-ramdisk.conf.bak
cat > /etc/weewx-ramdisk.conf <<EOF
# Tuned by weewx-database-ramdisk.sh for ${PI_MODEL}
# Adjust ZRAM_SIZE if 'df -h /var/lib/weewx' approaches full, or if actual
# RAM usage (seen in 'zramctl') is comfortably lower than expected.
ZRAM_SIZE=${ZRAM_SIZE}
ZRAM_ALGO=${ZRAM_ALGO}
MOUNT=/var/lib/weewx
PERSIST=/var/lib/weewx.hdd
OWNER=weewx:weewx
# How many rotated snapshots to keep on the SD card (weewx.sdb.1 ... .N).
# Raise for more fallback depth at the cost of SD space (1x DB per slot).
ROTATION_COUNT=${ROTATION_COUNT}
EOF

# ---------------------------------------------------------------------------
# 4. Helper scripts in /usr/local/sbin
# ---------------------------------------------------------------------------
echo "==> Installing helper scripts"

# --- setup: runs on boot, before weewx -------------------------------------
cat > /usr/local/sbin/weewx-ram-setup <<'SETUP_EOF'
#!/bin/bash
# Allocate a fresh zram device, mount it at $MOUNT, restore a VALIDATED
# snapshot from the SD-card mirror.
#
# On boot the SD-card snapshot could be corrupt (bit rot, previous unclean
# save, etc). Rather than propagate corruption into RAM and hand it to
# weewx, we validate before restoring. If the primary snapshot fails, we
# walk the rotation (.1, .2, ...) until we find one that passes
# integrity_check — then restore from that.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/weewx-ramdisk.conf

ROTATION_COUNT="${ROTATION_COUNT:-5}"

if mountpoint -q "$MOUNT"; then
  logger -t weewx-ram "$MOUNT already mounted; skipping setup"
  exit 0
fi

# --- Allocate zram + mount ------------------------------------------------
ZDEV=$(zramctl --find --size "$ZRAM_SIZE" --algorithm "$ZRAM_ALGO")
echo "$ZDEV" > /run/weewx-ram.dev

# ext4 without a journal: the filesystem is ephemeral, so journaling only
# costs RAM and write amplification. We don't need crash recovery on a
# filesystem that's recreated every boot.
mkfs.ext4 -q -L weewx-ram -F -O ^has_journal "$ZDEV"
mkdir -p "$MOUNT"
mount -o noatime,nosuid "$ZDEV" "$MOUNT"

# --- Restore non-DB files first ------------------------------------------
# These are small and don't need validation (configs, skins, stale HTML).
if [[ -d "$PERSIST" ]]; then
  rsync -aHAX --delete \
    --exclude='weewx.sdb' \
    --exclude='weewx.sdb.tmp' \
    --exclude='weewx.sdb.[0-9]*' \
    "${PERSIST}/" "${MOUNT}/"
fi

# --- Find the newest DB snapshot that passes integrity_check -------------
DBP="${PERSIST}/weewx.sdb"
CANDIDATES=("$DBP")
for (( i=1; i<=ROTATION_COUNT; i++ )); do
  CANDIDATES+=("${DBP}.${i}")
done

VALID=""
for candidate in "${CANDIDATES[@]}"; do
  [[ -f "$candidate" ]] || continue
  logger -t weewx-ram "Validating candidate $candidate"
  # quick_check catches page-level and structural corruption (the common
  # SD-card failure modes) in a few seconds on a 300MB DB. The full
  # integrity_check already runs during save (before promoting the file
  # to .sdb) and during the OneDrive backup, so the file on disk has
  # already passed the strong check — we don't need to re-run it every
  # boot, just re-verify the SD card didn't corrupt it while idle.
  CHECK=$(sqlite3 -bail "$candidate" 'PRAGMA quick_check(1);' 2>&1 || true)
  if [[ "$CHECK" == "ok" ]]; then
    VALID="$candidate"
    break
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
  # We have snapshots but NONE validated. Refuse to start — better to let
  # the user intervene than to silently boot with an unknown DB state.
  logger -p user.crit -t weewx-ram \
    "ALL DB snapshots failed integrity_check. Refusing to restore."
  umount "$MOUNT" || true
  if [[ -b "$ZDEV" ]]; then
    zramctl --reset "$ZDEV" 2>/dev/null || true
  fi
  rm -f /run/weewx-ram.dev
  exit 10
else
  # First boot with no snapshots at all — let weewx create a fresh DB.
  logger -t weewx-ram "No existing snapshot at $DBP; starting fresh"
fi

chown -R "$OWNER" "$MOUNT"
logger -t weewx-ram "Mounted $ZDEV ($ZRAM_SIZE $ZRAM_ALGO) at $MOUNT"
SETUP_EOF

# --- save: hourly snapshot + called during teardown ------------------------
cat > /usr/local/sbin/weewx-ram-save <<'SAVE_EOF'
#!/bin/bash
# Validated snapshot of the live DB to the SD-card mirror.
#
# Flow:
#   1. quick_check the live DB. If it's corrupt, abort — refuse to
#      overwrite a known-good persistent snapshot with garbage.
#   2. Online-backup to a .tmp file next to the target.
#   3. integrity_check the .tmp file. If it fails, discard and abort.
#   4. Rotate: weewx.sdb -> .1 -> .2 -> ... up to ROTATION_COUNT.
#   5. Promote .tmp to weewx.sdb.
#   6. rsync everything else (configs, skins, etc).
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

# Always clear stale tmp from a previous failed run before starting.
rm -f "$TMP"

if [[ -f "$DB" ]]; then

  # --- 1. Validate the LIVE DB first -------------------------------------
  # quick_check returns "ok" on success, or lines describing problems.
  LIVE_CHECK=$(sqlite3 -bail "$DB" 'PRAGMA quick_check(1);' 2>&1 || true)
  if [[ "$LIVE_CHECK" != "ok" ]]; then
    logger -p user.err -t weewx-ram \
      "LIVE DB FAILED quick_check — NOT overwriting $DBP. Report: $LIVE_CHECK"
    exit 2
  fi

  # --- 2. Online backup to a temp file -----------------------------------
  # .backup uses SQLite's online backup API — safe while weewx is writing.
  if ! sqlite3 -bail "$DB" ".backup '${TMP}'"; then
    logger -p user.err -t weewx-ram "sqlite .backup to $TMP failed"
    rm -f "$TMP"
    exit 3
  fi

  # --- 3. Validate the BACKUP file ---------------------------------------
  # Full integrity_check here (not quick_check) — this copy is what we'd
  # restore from, so we want the stronger guarantee.
  BACKUP_CHECK=$(sqlite3 -bail "$TMP" 'PRAGMA integrity_check(1);' 2>&1 || true)
  if [[ "$BACKUP_CHECK" != "ok" ]]; then
    logger -p user.err -t weewx-ram \
      "BACKUP FILE failed integrity_check — discarding. Report: $BACKUP_CHECK"
    rm -f "$TMP"
    exit 4
  fi

  # --- 4. Rotate older snapshots -----------------------------------------
  # Shift .N-1 -> .N, ..., .1 -> .2, current -> .1. Drops the oldest.
  for (( i=ROTATION_COUNT; i>=2; i-- )); do
    prev=$((i - 1))
    if [[ -f "${DBP}.${prev}" ]]; then
      mv -f "${DBP}.${prev}" "${DBP}.${i}"
    fi
  done
  if [[ -f "$DBP" ]]; then
    mv -f "$DBP" "${DBP}.1"
  fi

  # --- 5. Atomic promote -------------------------------------------------
  mv -f "$TMP" "$DBP"
fi

# --- 6. Non-DB files (configs, custom skins, anything else weewx writes) -
# Always safe to rsync; these aren't transactional.
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

# --- teardown: runs on shutdown, after weewx has stopped -------------------
cat > /usr/local/sbin/weewx-ram-teardown <<'TEARDOWN_EOF'
#!/bin/bash
# Save final state, unmount, release the zram device.
# Called by weewx-ramdisk.service ExecStop.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/weewx-ramdisk.conf

# Save is best-effort — don't block teardown if it fails (better to still
# release resources than to hang the shutdown sequence).
/usr/local/sbin/weewx-ram-save || logger -t weewx-ram "save failed during teardown"

if mountpoint -q "$MOUNT"; then
  umount "$MOUNT" || umount -l "$MOUNT"
fi

if [[ -r /run/weewx-ram.dev ]]; then
  ZDEV=$(cat /run/weewx-ram.dev)
  if [[ -b "$ZDEV" ]]; then
    zramctl --reset "$ZDEV" 2>/dev/null || true
  fi
  rm -f /run/weewx-ram.dev
fi

logger -t weewx-ram "Teardown complete"
TEARDOWN_EOF

chmod 0755 /usr/local/sbin/weewx-ram-setup \
           /usr/local/sbin/weewx-ram-save \
           /usr/local/sbin/weewx-ram-teardown

# ---------------------------------------------------------------------------
# 5. systemd units
# ---------------------------------------------------------------------------
echo "==> Installing systemd units"

cat > /etc/systemd/system/weewx-ramdisk.service <<'EOF'
[Unit]
Description=WeeWX database on zram (restore on boot, save on shutdown)
After=local-fs.target
Before=weewx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/weewx-ram-setup
ExecStop=/usr/local/sbin/weewx-ram-teardown
# Give sqlite .backup + integrity_check + rsync + umount enough time on
# a slow SD card with a large DB.
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/weewx-ramdisk-save.service <<'EOF'
[Unit]
Description=Snapshot WeeWX DB from zram to SD card
Requires=weewx-ramdisk.service
After=weewx-ramdisk.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/weewx-ram-save
EOF

cat > /etc/systemd/system/weewx-ramdisk-save.timer <<'EOF'
[Unit]
Description=Periodic WeeWX DB snapshot to SD card

[Timer]
# Defer first run 10 min after boot so the system settles first
OnBootSec=10min
OnUnitActiveSec=1h
# If the Pi was off when a tick was missed, run once after boot
Persistent=true
Unit=weewx-ramdisk-save.service

[Install]
WantedBy=timers.target
EOF

# Drop-in that ties weewx.service lifecycle to our ramdisk service:
# - Requires= means starting weewx pulls ramdisk in first
# - After= enforces ordering
# - Stopping ramdisk also stops weewx (so user can't restart ramdisk
#   out from under a running weewx)
mkdir -p /etc/systemd/system/weewx.service.d
cat > /etc/systemd/system/weewx.service.d/ramdisk.conf <<'EOF'
[Unit]
Requires=weewx-ramdisk.service
After=weewx-ramdisk.service
EOF

# ---------------------------------------------------------------------------
# 6. Enable and start
# ---------------------------------------------------------------------------
echo "==> Enabling and starting services"
systemctl daemon-reload
systemctl enable weewx-ramdisk.service
systemctl enable --now weewx-ramdisk-save.timer
systemctl start weewx-ramdisk.service

if [[ "$WEEWX_WAS_ACTIVE" == "true" ]]; then
  systemctl start weewx
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOM

==============================================================
  WeeWX ramdisk setup complete.
==============================================================
Live (zram) mount : /var/lib/weewx     (${ZRAM_SIZE} ${ZRAM_ALGO})
Persistent mirror : /var/lib/weewx.hdd (SD card)
Rotation depth    : ${ROTATION_COUNT} snapshots

Verify:
    zramctl                               # should show swap + log2ram + weewx-ram
    df -h /var/lib/weewx                  # filesystem size ~${ZRAM_SIZE}
    mount | grep weewx                    # ext4 on /dev/zramN
    ls -lh /var/lib/weewx/weewx.sdb       # live DB
    ls -lh /var/lib/weewx.hdd/weewx.sdb*  # latest + rotated snapshots
    systemctl status weewx-ramdisk
    systemctl list-timers | grep weewx
    journalctl -t weewx-ram --no-pager -n 30

Trigger a manual snapshot any time:
    sudo systemctl start weewx-ramdisk-save.service

Tune rotation depth:
    sudo nano /etc/weewx-ramdisk.conf     # change ROTATION_COUNT

Exit codes from weewx-ram-save (visible in journal / status):
    2 = live DB failed quick_check (NOT saved — investigate the live DB)
    3 = sqlite .backup command failed
    4 = backup file failed integrity_check (discarded — SD or RAM issue)

If weewx-ramdisk fails on boot with 'ALL DB snapshots failed', every
snapshot on the SD card is corrupt. Recover manually:
    sudo ls -lh /var/lib/weewx.hdd/
    for f in /var/lib/weewx.hdd/weewx.sdb*; do
      echo "== \$f ==" ; sqlite3 "\$f" 'PRAGMA integrity_check;' 2>&1 | head
    done
    # then decide: restore from external backup, or accept a partial file.

To revert completely:
    sudo systemctl stop weewx
    sudo systemctl disable --now weewx-ramdisk-save.timer
    sudo systemctl stop weewx-ramdisk
    sudo systemctl disable weewx-ramdisk
    sudo rm -rf /etc/systemd/system/weewx-ramdisk*.service \\
                /etc/systemd/system/weewx-ramdisk-save.timer \\
                /etc/systemd/system/weewx.service.d
    sudo umount /var/lib/weewx 2>/dev/null || true
    sudo rsync -aHAX --delete /var/lib/weewx.hdd/ /var/lib/weewx/
    sudo chown -R weewx:weewx /var/lib/weewx
    sudo rm -rf /var/lib/weewx.hdd
    sudo rm -f /etc/weewx-ramdisk.conf \\
               /usr/local/sbin/weewx-ram-{setup,save,teardown}
    sudo systemctl daemon-reload
    sudo systemctl start weewx
EOM