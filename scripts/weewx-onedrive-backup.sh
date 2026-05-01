#!/bin/bash
# weewx-onedrive-backup.sh
# Install daily / weekly / monthly WeeWX SQLite backups to OneDrive using
# rclone + systemd timers. Each backup is compressed with zstd, integrity-
# checked with sqlite, and uploaded to a tier-specific folder. Old files
# are pruned automatically.
#
# Retention (tweak in /usr/local/sbin/weewx-onedrive-backup if desired):
#   daily   : 7 days
#   weekly  : 8 weeks  (every Sunday)
#   monthly : 12 months (every 1st)
#
# Prerequisites:
#   - weewx-database-ramdisk.sh installed (this script reads /etc/weewx-ramdisk.conf)
#   - Internet connectivity
#
# This script is idempotent — you'll run it twice:
#   1. First run installs rclone and asks you to set up the OneDrive remote
#      (recommended: do `rclone config` on Windows/Mac, then copy the
#      resulting rclone.conf to the Pi — the headless OAuth flow is fragile
#      on Windows because Defender / browsers often consume the auth code
#      before rclone can use it).
#   2. After the rclone remote exists on the Pi, re-run this script to
#      install the backup script + systemd timers.
#
# Re-running after install is safe: existing folders / units / config are
# detected and reused.
#
# Run as root.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Single source of truth for the OneDrive layout.
# Change REMOTE_ROOT here to move every tier in one go; the value is
# written to /etc/weewx-onedrive-backup.conf and sourced by the runtime
# backup script, so the installed script picks up the change on the next
# install run.
# ---------------------------------------------------------------------------
REMOTE_NAME="onedrive"
REMOTE_ROOT="Documents-Private/Backups/WeeWX/Database"
BACKUP_BIN="/usr/local/sbin/weewx-onedrive-backup"
BACKUP_CONF="/etc/weewx-onedrive-backup.conf"
CONF_FILE="/root/.config/rclone/rclone.conf"

if [[ ! -f /etc/weewx-ramdisk.conf ]]; then
  echo "Missing /etc/weewx-ramdisk.conf — run weewx-database-ramdisk.sh first." >&2
  exit 1
fi

# --- 1. Install dependencies --------------------------------------------
echo "Installing rclone + zstd + sqlite3 (idempotent)..."
apt-get update -qq
apt-get install -y rclone zstd sqlite3

# --- 2. Check for the OneDrive remote -----------------------------------
if ! rclone --config "$CONF_FILE" listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
  cat <<'INSTRUCTIONS'
============================================================
  NEXT STEP: configure rclone's OneDrive remote
============================================================

rclone is installed on the Pi, but the 'onedrive' remote isn't set
up yet. The easy path is to do the OAuth on a machine that has a
working browser (Windows/Mac) and copy the resulting config file to
the Pi. The headless two-machine flow has known issues with Windows
Defender / browser prefetchers consuming the auth code before rclone
can exchange it.

============================================================
  Option A — configure on Windows, copy to Pi (RECOMMENDED)
============================================================
On your Windows machine:
  1. Install rclone:   winget install Rclone.Rclone
     (or download from https://rclone.org/downloads/)
  2. Run:  rclone config
  3. Answer the prompts:
       n                         (new remote)
       name> onedrive
       Storage> onedrive
       client_id>     (blank for rclone's default, OR your Azure app's
                       Application (client) ID if you registered one)
       client_secret> (blank for default, OR your Azure app's secret
                       VALUE — not the Secret ID)
       region> 1                 (Microsoft Cloud Global)
       tenant>                   (LEAVE BLANK — personal accounts
                                  don't live in a tenant)
       Edit advanced config> n
       Use web browser> y        (Windows has one — much more reliable)
  4. Browser opens → sign in to your Microsoft account → Accept
  5. Back in PowerShell:
       config_type> 1            (OneDrive Personal or Business)
       Select drive>             pick the row labeled
                                 "OneDrive (personal)" — its drive ID
                                 is a 16-char hex string like
                                 F182ABB27218A4EC. Don't pick rows
                                 with b!... long IDs — those are
                                 internal document libraries.
       Drive OK> y
       Keep this "onedrive" remote> y
       final menu> q             (quit)
  6. Smoke test:
       rclone listremotes        → should print: onedrive:
       rclone lsd onedrive:      → should list your OneDrive folders
  7. Copy the config to this Pi. From PowerShell:
       scp $env:APPDATA\rclone\rclone.conf <user>@<pi>:/tmp/rclone.conf

Then on the Pi:
  sudo mkdir -p /root/.config/rclone
  sudo mv /tmp/rclone.conf /root/.config/rclone/rclone.conf
  sudo chown root:root    /root/.config/rclone/rclone.conf
  sudo chmod 600          /root/.config/rclone/rclone.conf
  sudo rclone listremotes
  sudo rclone lsd onedrive:       # should list your OneDrive folders

Finally, re-run this installer to finish:
  sudo bash weewx-onedrive-backup.sh

============================================================
  If you registered your own Azure app, confirm these settings:
============================================================
  Authentication → Platform configurations:
      Web  →  http://localhost:53682/       (with trailing slash)
      (NOT "Mobile and desktop applications" — that causes
       AADSTS70000 "code has expired" errors on token exchange)
  Authentication → Supported account types:
      Accounts in any organizational directory and personal
      Microsoft accounts
  Manifest:
      "signInAudience": "AzureADandPersonalMicrosoftAccount"
      "requestedAccessTokenVersion": 2
  API permissions → Microsoft Graph (Delegated):
      Files.ReadWrite.All
      offline_access                         (critical for renewals)
  Certificates & secrets:
      Use the Value column (long, with ~ and . chars),
      NOT the Secret ID column (GUID format).
      Azure only shows the full Value ONCE at creation —
      copy it immediately.

============================================================
  Option B — headless config on the Pi (only if no desktop machine)
============================================================
  sudo rclone config
  ... answer the same prompts, but:
       Use web browser> n
  rclone prints an "rclone authorize" command with a base64 blob.
  Run that command on any machine with a browser (same rclone major
  version), sign in, copy the full JSON result back to the Pi's
  "Enter a value." prompt. If your browser / AV keeps consuming the
  auth code, use Option A instead.
INSTRUCTIONS
  exit 0
fi

echo "OneDrive remote '${REMOTE_NAME}' is configured."

# Quick connectivity test (doesn't upload anything).
if ! rclone --config "$CONF_FILE" lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
  echo "ERROR: can reach '${REMOTE_NAME}:' but listing failed. Check auth with: sudo rclone config reconnect ${REMOTE_NAME}:"
  exit 1
fi

# --- Verify / create the OneDrive folder tree ---------------------------
# Idempotent: walk each path segment and create the ones that don't exist.
# Shows exactly what's being created vs what was already there so typos
# in $REMOTE_ROOT surface before any data is uploaded.
ensure_remote_dir() {
  local dir="$1"
  local parent leaf
  if [[ "$dir" == */* ]]; then
    parent="${dir%/*}"
  else
    parent=""
  fi
  leaf="${dir##*/}"

  if rclone --config "$CONF_FILE" lsf --dirs-only "${REMOTE_NAME}:${parent}" 2>/dev/null \
     | grep -qx "${leaf}/"; then
    echo "  [exists]  ${REMOTE_NAME}:${dir}"
  else
    echo "  [create]  ${REMOTE_NAME}:${dir}"
    if ! rclone --config "$CONF_FILE" mkdir "${REMOTE_NAME}:${dir}"; then
      echo "ERROR: failed to create ${REMOTE_NAME}:${dir}" >&2
      exit 1
    fi
  fi
}

echo
echo "Verifying OneDrive folder tree under ${REMOTE_NAME}:${REMOTE_ROOT}/ ..."

# Walk the parent path one segment at a time
# (Documents-Private, then Documents-Private/Backups, then ...).
ACCUM=""
IFS='/' read -ra PARTS <<< "$REMOTE_ROOT"
for PART in "${PARTS[@]}"; do
  ACCUM="${ACCUM:+${ACCUM}/}${PART}"
  ensure_remote_dir "$ACCUM"
done

# Then the three tier folders.
for TIER in daily weekly monthly; do
  ensure_remote_dir "${REMOTE_ROOT}/${TIER}"
done

echo

# --- 3. Write runtime config + install the backup script ----------------
# The runtime script sources $BACKUP_CONF instead of hardcoding paths,
# so REMOTE_ROOT / REMOTE_NAME live in exactly one place (this installer).
cat > "$BACKUP_CONF" <<CONF
# /etc/weewx-onedrive-backup.conf
# Generated by weewx-onedrive-backup.sh — re-run that script to refresh.
# REMOTE_ROOT is the single source of truth for the backup layout; the
# tier subfolders (daily/weekly/monthly) are appended at runtime.
REMOTE_NAME="${REMOTE_NAME}"
REMOTE_ROOT="${REMOTE_ROOT}"
CONF_FILE="${CONF_FILE}"
CONF
chmod 0644 "$BACKUP_CONF"
echo "Wrote $BACKUP_CONF (REMOTE_ROOT=${REMOTE_ROOT})"

install -d /usr/local/sbin
cat > "$BACKUP_BIN" <<'BACKUP_EOF'
#!/bin/bash
# /usr/local/sbin/weewx-onedrive-backup
# Compress + integrity-check + upload weewx.sdb to OneDrive, then prune.
# Called by systemd timers. Usage: weewx-onedrive-backup {daily|weekly|monthly}
set -euo pipefail

# shellcheck disable=SC1091
source /etc/weewx-onedrive-backup.conf
# shellcheck disable=SC1091
source /etc/weewx-ramdisk.conf

TIER="${1:-daily}"
case "$TIER" in
  daily)    KEEP_AGE="7d"   ;;   # ~1 week
  weekly)   KEEP_AGE="56d"  ;;   # ~8 weeks
  monthly)  KEEP_AGE="400d" ;;   # ~13 months (slightly over 12 to be safe)
  *) echo "Usage: $0 {daily|weekly|monthly}" >&2; exit 2 ;;
esac

REMOTE_PATH="${REMOTE_ROOT}/${TIER}"
DB_SRC="${PERSIST}/weewx.sdb"

# --- 1. Force a fresh validated save to PERSIST before we copy ----------
# Hourly timer already keeps this within an hour, but an explicit save
# guarantees the backup reflects the latest good state of the DB.
logger -t weewx-onedrive "[$TIER] Triggering fresh weewx-ram-save"
if ! /usr/local/sbin/weewx-ram-save; then
  logger -p user.warning -t weewx-onedrive \
    "[$TIER] weewx-ram-save returned non-zero — backing up whatever is currently at $DB_SRC"
fi

if [[ ! -f "$DB_SRC" ]]; then
  logger -p user.err -t weewx-onedrive "[$TIER] No DB at $DB_SRC — aborting"
  exit 1
fi

# --- 2. Validate the snapshot we're about to upload ---------------------
CHECK=$(sqlite3 -bail "$DB_SRC" 'PRAGMA integrity_check(1);' 2>&1 || true)
if [[ "$CHECK" != "ok" ]]; then
  logger -p user.err -t weewx-onedrive \
    "[$TIER] integrity_check FAILED on $DB_SRC — refusing to upload. Report: $CHECK"
  exit 3
fi

# --- 3. Compose tier-appropriate filename ------------------------------
case "$TIER" in
  daily)    STAMP=$(date +%Y-%m-%d) ;;
  weekly)   STAMP=$(date +%G-W%V)   ;;   # ISO year-week
  monthly)  STAMP=$(date +%Y-%m)    ;;
esac
NAME="weewx-${STAMP}.sdb.zst"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Auto-tune zstd level + threads based on hardware -----------------
# Level 19 is ~15 min on a Pi 3, ~2 min on a Pi 4, <1 min on a Pi 5.
# We pick a level that keeps each run under a few minutes on the device
# while still compressing well (the DB is mostly zeros + text, so even
# level -6 gets >85% reduction).
#
# Override either value at runtime if needed, e.g.:
#   sudo ZSTD_LEVEL=3 systemctl start weewx-onedrive-backup-daily.service
detect_zstd_params() {
  # Respect explicit overrides first.
  local level="${ZSTD_LEVEL:-}"
  local threads="${ZSTD_THREADS:-}"
  local model=""

  if [[ -r /proc/device-tree/model ]]; then
    # /proc/device-tree/model is a null-terminated string on Pi kernels.
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
    # zstd -T0 uses all cores, but we prefer a fixed number for
    # predictable scheduling under Nice=15 / IOSchedulingClass=idle.
    threads="$nproc_count"
  fi

  echo "${level} ${threads} ${model:-unknown}"
}

read -r ZLEVEL ZTHREADS ZMODEL <<< "$(detect_zstd_params)"
logger -t weewx-onedrive \
  "[$TIER] Compressing with zstd -${ZLEVEL} -T${ZTHREADS} (detected: ${ZMODEL})"

zstd -q "-${ZLEVEL}" "-T${ZTHREADS}" -o "${TMPDIR}/${NAME}" "$DB_SRC"
SIZE=$(stat -c%s "${TMPDIR}/${NAME}")

# --- 4. Upload ---------------------------------------------------------
logger -t weewx-onedrive "[$TIER] Uploading $NAME (${SIZE} bytes) to ${REMOTE_PATH}/"
if ! rclone copy "${TMPDIR}/${NAME}" "${REMOTE_NAME}:${REMOTE_PATH}/" \
      --config "$CONF_FILE" \
      --stats 0 --transfers 1 --retries 3 --low-level-retries 10; then
  logger -p user.err -t weewx-onedrive "[$TIER] Upload of $NAME FAILED"
  exit 4
fi
logger -t weewx-onedrive "[$TIER] Upload complete: $NAME"

# --- 5. Prune old files in this tier ----------------------------------
# --min-age deletes files older than N, leaving anything newer intact.
if rclone delete "${REMOTE_NAME}:${REMOTE_PATH}/" \
     --config "$CONF_FILE" \
     --min-age "$KEEP_AGE" --stats 0; then
  logger -t weewx-onedrive "[$TIER] Pruned files older than $KEEP_AGE"
else
  logger -p user.warning -t weewx-onedrive "[$TIER] Prune step failed (not fatal)"
fi
BACKUP_EOF
chmod 0755 "$BACKUP_BIN"
echo "Installed $BACKUP_BIN"

# --- 4. Install systemd services + timers --------------------------------
# Schedule spacing:
#   daily   : 02:30  (every day)
#   weekly  : 03:30  (Sundays)
#   monthly : 04:30  (1st of month)
# With RandomizedDelaySec=10min on each, the closest two can ever get is
# ~50 minutes — well beyond any realistic backup runtime. Plus each
# service declares `After=` the previous tier, so if they ever do race
# systemd will queue them in order instead of running them concurrently
# (which would be bad for weewx-ram-save writing to the same file).

cat > "/etc/systemd/system/weewx-onedrive-backup-daily.service" <<SERVICE
[Unit]
Description=WeeWX daily backup to OneDrive
After=network-online.target weewx-ramdisk.service
Wants=network-online.target
ConditionPathExists=/etc/weewx-ramdisk.conf
ConditionPathExists=/etc/weewx-onedrive-backup.conf

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=${BACKUP_BIN} daily
# Don't let a stuck upload wedge the timer forever.
TimeoutStartSec=30min
SERVICE

cat > "/etc/systemd/system/weewx-onedrive-backup-weekly.service" <<SERVICE
[Unit]
Description=WeeWX weekly backup to OneDrive
After=network-online.target weewx-ramdisk.service weewx-onedrive-backup-daily.service
Wants=network-online.target
ConditionPathExists=/etc/weewx-ramdisk.conf
ConditionPathExists=/etc/weewx-onedrive-backup.conf

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=${BACKUP_BIN} weekly
TimeoutStartSec=30min
SERVICE

cat > "/etc/systemd/system/weewx-onedrive-backup-monthly.service" <<SERVICE
[Unit]
Description=WeeWX monthly backup to OneDrive
After=network-online.target weewx-ramdisk.service weewx-onedrive-backup-daily.service weewx-onedrive-backup-weekly.service
Wants=network-online.target
ConditionPathExists=/etc/weewx-ramdisk.conf
ConditionPathExists=/etc/weewx-onedrive-backup.conf

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=${BACKUP_BIN} monthly
TimeoutStartSec=30min
SERVICE

cat > /etc/systemd/system/weewx-onedrive-backup-daily.timer <<'TIMER'
[Unit]
Description=Daily WeeWX backup to OneDrive

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=10min
Unit=weewx-onedrive-backup-daily.service

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/weewx-onedrive-backup-weekly.timer <<'TIMER'
[Unit]
Description=Weekly WeeWX backup to OneDrive

[Timer]
OnCalendar=Sun 03:30:00
Persistent=true
RandomizedDelaySec=10min
Unit=weewx-onedrive-backup-weekly.service

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/weewx-onedrive-backup-monthly.timer <<'TIMER'
[Unit]
Description=Monthly WeeWX backup to OneDrive

[Timer]
OnCalendar=*-*-01 04:30:00
Persistent=true
RandomizedDelaySec=10min
Unit=weewx-onedrive-backup-monthly.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now \
  weewx-onedrive-backup-daily.timer \
  weewx-onedrive-backup-weekly.timer \
  weewx-onedrive-backup-monthly.timer

echo
echo "============================================================"
echo "  Scheduled backups installed."
echo "============================================================"
systemctl list-timers 'weewx-onedrive-backup-*.timer' --no-pager || true

cat <<NEXT

Run a backup now to verify end-to-end (uploads a daily):
  sudo systemctl start weewx-onedrive-backup-daily.service
  journalctl -t weewx-onedrive -n 30 --no-pager

Check it landed:
  rclone --config ${CONF_FILE} \\
    lsl ${REMOTE_NAME}:${REMOTE_ROOT}/daily

Restore test (download + decompress to a temp file):
  rclone --config ${CONF_FILE} \\
    copy ${REMOTE_NAME}:${REMOTE_ROOT}/daily/weewx-YYYY-MM-DD.sdb.zst /tmp/
  zstd -d /tmp/weewx-YYYY-MM-DD.sdb.zst -o /tmp/weewx-restored.sdb
  sqlite3 /tmp/weewx-restored.sdb 'PRAGMA integrity_check;'
NEXT