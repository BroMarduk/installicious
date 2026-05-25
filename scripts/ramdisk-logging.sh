#!/bin/bash
# ramdisk-logging.sh
# Combined zram + log2ram setup to reduce SD card wear on Raspberry Pi.
# Target: Raspberry Pi OS (Bullseye / Bookworm)
# Run:    sudo bash ramdisk-logging.sh
#
# What it does:
#   1. Installs zram-tools (zram swap) and log2ram (RAM-backed /var/log).
#   2. Configures zram swap sized to ~50% of RAM, zstd-compressed.
#      Disables dphys-swapfile (the old SD-card swapfile).
#   3. Mounts /tmp on tmpfs so temp files never hit the SD card.
#   4. Configures log2ram to use zram as its backing store (ZL2R=true),
#      so /var/log is in compressed RAM. Syncs to SD once per hour.
#   5. Tunes logrotate: daily + maxsize 5M, xz-compressed, hourly cron.
#   6. Sets journald to persistent storage under /var/log/journal so log2ram can buffer it.
#   7. Adds 'noatime' to the root mount to eliminate atime writes.
#
# All modified config files are backed up with a .bak suffix.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect OS version (Debian/RPi OS: bullseye=11, bookworm=12, trixie=13+)
# ---------------------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-0}"
  OS_CODENAME="${VERSION_CODENAME:-unknown}"
else
  echo "WARN: /etc/os-release not found — assuming legacy Debian-based system." >&2
  OS_ID="debian"
  OS_VERSION_ID="0"
  OS_CODENAME="unknown"
fi

echo "Detected OS: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME})"

# log2ram entered the main Debian repo at Trixie (Debian 13).
# On Bullseye/Bookworm we still need the azlux third-party repo.
if (( OS_VERSION_ID >= 13 )); then
  USE_AZLUX_REPO=false
else
  USE_AZLUX_REPO=true
fi

# ---------------------------------------------------------------------------
# Detect Pi model (for per-SoC tuning — CPU class drives compression choice)
# ---------------------------------------------------------------------------
PI_MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
  PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
fi
echo "Detected model: ${PI_MODEL}"

# Compression algorithm: lz4 on Cortex-A53 (Pi 2 v1.2 / 3 / Zero 2 W / 3A+)
# and older ARMv6 (original Pi / Zero / Zero W), where CPU is the bottleneck.
# zstd on Cortex-A72/A76 (Pi 4 / 5 / CM4) where compression ratio wins.
case "$PI_MODEL" in
  *"Pi 5"*|*"Pi 4"*|*"Compute Module 4"*|*"Pi 400"*)
    ZRAM_ALGO=zstd
    ;;
  *"Pi 3"*|*"Pi 2"*|*"Zero 2"*|*"Compute Module 3"*|*"Pi Zero"*|*"Pi Model"*)
    ZRAM_ALGO=lz4
    ;;
  *)
    # Unknown — err toward lz4 (universally supported, lighter on CPU)
    ZRAM_ALGO=lz4
    ;;
esac

# Aggressive swappiness makes sense with zram: pushing pages to compressed
# RAM is cheap compared to disk swap. 80 is a widely recommended value.
VM_SWAPPINESS=80
VM_VFS_CACHE_PRESSURE=50

# ---------------------------------------------------------------------------
# Sizing based on detected RAM (and Pi class)
# ---------------------------------------------------------------------------
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
echo "Detected RAM: ${RAM_MB} MB"

if   (( RAM_MB >= 3500 )); then
  # Pi 4 4GB+ / Pi 5 — roomy, zstd for best compression
  SWAP_PCT=50; LOG_SIZE=256M; LOG_DISK=512M; TMP_SIZE=200M
elif (( RAM_MB >= 1800 )); then
  # Pi 4 2GB / CM4 2GB
  SWAP_PCT=50; LOG_SIZE=128M; LOG_DISK=256M; TMP_SIZE=150M
else
  # Pi 3 / Zero 2 W / 3A+ / older — tight budget, modest sizing
  SWAP_PCT=40; LOG_SIZE=48M;  LOG_DISK=96M;  TMP_SIZE=64M
fi

echo "Sizing -> swap ${SWAP_PCT}% (${ZRAM_ALGO}) | /var/log ${LOG_SIZE} (zram ${LOG_DISK} ${ZRAM_ALGO}) | /tmp ${TMP_SIZE}"
echo "Tuning -> vm.swappiness=${VM_SWAPPINESS}, vm.vfs_cache_pressure=${VM_VFS_CACHE_PRESSURE}"

# ---------------------------------------------------------------------------
# Detect zram swap manager (precedence order matters — the thing that WINS
# at boot-time generator execution is what we have to configure):
#   - rpi-swap:               Pi OS Trixie default. Ships rpi-swap-generator
#                             which generates /run/systemd/generator/dev-zram0.swap
#                             and supersedes systemd-zram-generator's output.
#                             Config lives in /etc/rpi/swap.conf[.d/*.conf].
#   - systemd-zram-generator: Generic Debian Trixie. /etc/systemd/zram-generator.conf.
#   - zram-tools:             Bullseye/Bookworm. /etc/default/zramswap.
# ---------------------------------------------------------------------------
if dpkg -l rpi-swap 2>/dev/null | grep -q '^ii'; then
  SWAP_MANAGER="rpi-swap"
elif dpkg -l systemd-zram-generator 2>/dev/null | grep -q '^ii'; then
  SWAP_MANAGER="systemd-zram-generator"
elif (( OS_VERSION_ID >= 13 )); then
  SWAP_MANAGER="systemd-zram-generator"
else
  SWAP_MANAGER="zram-tools"
fi
echo "Swap manager: ${SWAP_MANAGER}"

# ---------------------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------------------
echo "==> Installing packages"
apt update

COMMON_PKGS="rsync wget gnupg ca-certificates xz-utils"
case "$SWAP_MANAGER" in
  rpi-swap)
    # rpi-swap is already installed on Pi OS. We install zram-tools for the
    # zramctl diagnostic tool but don't need anything else — the Pi-specific
    # rpi-swap-generator handles unit generation; we just tune its config.
    apt install -y zram-tools $COMMON_PKGS
    ;;
  systemd-zram-generator)
    # Install generator + zram-tools (for zramctl). The zramswap.service gets
    # disabled later to prevent it from fighting the generator.
    apt install -y systemd-zram-generator zram-tools $COMMON_PKGS
    ;;
  zram-tools)
    apt install -y zram-tools $COMMON_PKGS
    ;;
esac

# Sanity-check that xz is available at the path logrotate will use.
# Some minimal images don't include xz-utils; if the install above failed
# silently, fail fast here rather than breaking logrotate later.
if [[ ! -x /usr/bin/xz ]]; then
  echo "ERROR: /usr/bin/xz not found after installing xz-utils." >&2
  echo "       logrotate is configured to use it for compression." >&2
  echo "       Install manually with: sudo apt install -y xz-utils" >&2
  exit 1
fi

if ! command -v log2ram >/dev/null 2>&1; then
  if [[ "$USE_AZLUX_REPO" == "true" ]]; then
    echo "==> ${OS_CODENAME}: log2ram not in main repo, adding azlux third-party repo"
    wget -qO /usr/share/keyrings/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
    echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ stable main" \
      > /etc/apt/sources.list.d/azlux.list
    apt update
  else
    echo "==> ${OS_CODENAME}: installing log2ram from main Debian repo"
    # Clean up any stale azlux repo from a previous run on an older OS
    if [[ -f /etc/apt/sources.list.d/azlux.list ]]; then
      echo "   (removing stale azlux.list left over from previous OS version)"
      rm -f /etc/apt/sources.list.d/azlux.list
      rm -f /usr/share/keyrings/azlux-archive-keyring.gpg
      apt update
    fi
  fi
  apt install -y log2ram
fi

# ---------------------------------------------------------------------------
# 2. zram swap configuration (via $SWAP_MANAGER)
# ---------------------------------------------------------------------------
echo "==> Configuring zram swap (via ${SWAP_MANAGER})"

# Disable SD-card swapfile if present (older Pi OS). Trixie ships without it.
if systemctl list-unit-files dphys-swapfile.service >/dev/null 2>&1 \
   && systemctl is-enabled --quiet dphys-swapfile 2>/dev/null; then
  systemctl disable --now dphys-swapfile || true
fi

if [[ "$SWAP_MANAGER" == "rpi-swap" ]]; then
  # ----- rpi-swap path (Pi OS Trixie) -----
  # rpi-swap-generator produces the dev-zram0.swap unit from /etc/rpi/swap.conf
  # and wins over systemd-zram-generator. We configure it via a drop-in.
  # Compression algorithm is NOT set by rpi-swap — it defers to
  # systemd-zram-setup@zram0.service which reads /etc/systemd/zram-generator.conf.
  # So we write BOTH files: rpi-swap for size + mechanism, zram-generator for algo.

  # Convert SWAP_PCT (e.g. 40) to a decimal multiplier (e.g. 0.40) for rpi-swap.
  RAM_MULT=$(awk "BEGIN { printf \"%.2f\", $SWAP_PCT / 100 }")

  mkdir -p /etc/rpi/swap.conf.d
  CONF=/etc/rpi/swap.conf.d/99-pi-sd-saver.conf
  cat > "$CONF" <<EOF
# Tuned by ramdisk-logging.sh for ${PI_MODEL}
# Use zram-only (no file-backed writeback) so we don't write to the SD card
# under memory pressure — that's the whole point of this setup.
[Main]
Mechanism=zram

[Zram]
RamMultiplier=${RAM_MULT}
EOF

  # Write systemd-zram-generator config for the compression algorithm,
  # which rpi-swap defers to via systemd-zram-setup@zram0.service.
  ZCONF=/etc/systemd/zram-generator.conf
  [[ -f "$ZCONF" && ! -f "${ZCONF}.bak" ]] && cp "$ZCONF" "${ZCONF}.bak"
  cat > "$ZCONF" <<EOF
# Tuned by ramdisk-logging.sh for ${PI_MODEL}
# rpi-swap owns size + mechanism; this file contributes the compression algo.
[zram0]
compression-algorithm = ${ZRAM_ALGO}
swap-priority = 100
EOF

  # Disable zram-tools' service if installed — otherwise it duels with
  # rpi-swap's generated unit over /dev/zram0 at boot.
  if systemctl is-enabled --quiet zramswap.service 2>/dev/null; then
    echo "   (disabling zramswap.service to prevent conflict with rpi-swap)"
    systemctl disable --now zramswap.service 2>/dev/null || true
  fi

  echo "   (reconfiguring /dev/zram0 to match new config)"
  systemctl stop dev-zram0.swap 2>/dev/null || true
  systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
  for dev in /dev/zram*; do
    [[ -b "$dev" ]] || continue
    if grep -q "^${dev} " /proc/swaps 2>/dev/null; then
      swapoff "$dev" 2>/dev/null || true
    fi
  done
  if [[ -e /sys/block/zram0/reset ]] \
     && ! grep -qE "^/dev/zram0 " /proc/swaps /proc/mounts 2>/dev/null; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
  fi

  systemctl daemon-reload
  sleep 1
  systemctl start dev-zram0.swap 2>/dev/null || \
    echo "   (live restart failed — reboot once to pick up config cleanly)" >&2

elif [[ "$SWAP_MANAGER" == "systemd-zram-generator" ]]; then
  # ----- systemd-zram-generator path (generic Debian Trixie) -----
  CONF=/etc/systemd/zram-generator.conf
  [[ -f "$CONF" && ! -f "${CONF}.bak" ]] && cp "$CONF" "${CONF}.bak"

  cat > "$CONF" <<EOF
# Tuned by ramdisk-logging.sh for ${PI_MODEL}
[zram0]
zram-size = ram * ${SWAP_PCT} / 100
compression-algorithm = ${ZRAM_ALGO}
swap-priority = 100
EOF

  # If zram-tools' service is also enabled, disable it — two managers fighting
  # over /dev/zram0 is exactly why we're here. The package stays installed
  # (zramctl is useful), only the service is turned off.
  if systemctl is-enabled --quiet zramswap.service 2>/dev/null; then
    echo "   (disabling zramswap.service to prevent conflict with the generator)"
    systemctl disable --now zramswap.service 2>/dev/null || true
  fi

  echo "   (reconfiguring /dev/zram0 to match new config)"
  # Stop the swap unit (does swapoff), stop the setup service, reset device.
  systemctl stop dev-zram0.swap 2>/dev/null || true
  systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
  for dev in /dev/zram*; do
    [[ -b "$dev" ]] || continue
    if grep -q "^${dev} " /proc/swaps 2>/dev/null; then
      swapoff "$dev" 2>/dev/null || true
    fi
  done
  if [[ -e /sys/block/zram0/reset ]] \
     && ! grep -qE "^/dev/zram0 " /proc/swaps /proc/mounts 2>/dev/null; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || \
      echo "   (warning: could not reset /dev/zram0 — reboot may be needed)" >&2
  fi

  # daemon-reload re-runs the zram-generator against the new conf file
  systemctl daemon-reload
  sleep 1
  systemctl start dev-zram0.swap

else
  # ----- zram-tools path (Bullseye/Bookworm) -----
  [[ -f /etc/default/zramswap && ! -f /etc/default/zramswap.bak ]] && \
    cp /etc/default/zramswap /etc/default/zramswap.bak

  cat > /etc/default/zramswap <<EOF
# Tuned by ramdisk-logging.sh for ${PI_MODEL}
ALGO=${ZRAM_ALGO}
PERCENT=${SWAP_PCT}
PRIORITY=100
EOF

  systemctl enable zramswap.service

  echo "   (clearing any existing zram state before applying new config)"
  systemctl stop zramswap.service 2>/dev/null || true
  systemctl reset-failed zramswap.service 2>/dev/null || true

  for dev in /dev/zram*; do
    [[ -b "$dev" ]] || continue
    if grep -q "^${dev} " /proc/swaps 2>/dev/null; then
      swapoff "$dev" 2>/dev/null || true
    fi
  done

  if [[ -e /sys/block/zram0/reset ]] \
     && ! grep -qE "^/dev/zram0 " /proc/swaps /proc/mounts 2>/dev/null; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || \
      echo "   (warning: could not reset /dev/zram0 — reboot may be needed)" >&2
  fi

  sleep 1
  systemctl start zramswap.service
fi

# Verify regardless of which manager was used.
if [[ -b /dev/zram0 ]]; then
  ACTUAL_BYTES=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  ACTUAL_MB=$(( ACTUAL_BYTES / 1024 / 1024 ))
  EXPECTED_MB=$(( RAM_MB * SWAP_PCT / 100 ))
  MIN_MB=$(( EXPECTED_MB * 90 / 100 ))
  MAX_MB=$(( EXPECTED_MB * 110 / 100 ))
  ACTUAL_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null \
                | grep -oE '\[[^]]+\]' | tr -d '[]' || echo unknown)
  if (( ACTUAL_MB < MIN_MB || ACTUAL_MB > MAX_MB )) \
     || [[ "$ACTUAL_ALGO" != "$ZRAM_ALGO" ]]; then
    echo "   WARNING: zram swap is ${ACTUAL_MB}M ${ACTUAL_ALGO}, expected ~${EXPECTED_MB}M ${ZRAM_ALGO}." >&2
    echo "   Reboot once to clear stale state and the boot-time config will apply fresh." >&2
  else
    echo "   zram swap: ${ACTUAL_MB}M ${ACTUAL_ALGO} — OK"
  fi
fi

# ---------------------------------------------------------------------------
# 3. /tmp on tmpfs (avoids SD writes for short-lived temp files)
# ---------------------------------------------------------------------------
echo "==> Mounting /tmp on tmpfs"
if ! grep -qE '^\S+\s+/tmp\s+tmpfs' /etc/fstab; then
  [[ ! -f /etc/fstab.bak ]] && cp /etc/fstab /etc/fstab.bak
  echo "tmpfs  /tmp  tmpfs  defaults,noatime,nosuid,size=${TMP_SIZE}  0  0" >> /etc/fstab
fi

# ---------------------------------------------------------------------------
# 4. log2ram (with zram backing for compression)
# ---------------------------------------------------------------------------
echo "==> Configuring log2ram (ZL2R=true, ${ZRAM_ALGO} compression)"

# Trim /var/log so it fits on next boot (log2ram will refuse if oversize)
find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.[0-9]" -o -name "*.old" \) -delete 2>/dev/null || true
journalctl --vacuum-size=20M >/dev/null 2>&1 || true

[[ -f /etc/log2ram.conf && ! -f /etc/log2ram.conf.bak ]] && \
  cp /etc/log2ram.conf /etc/log2ram.conf.bak

sed -i \
  -e "s|^SIZE=.*|SIZE=${LOG_SIZE}|" \
  -e "s|^USE_RSYNC=.*|USE_RSYNC=true|" \
  -e "s|^MAIL=.*|MAIL=false|" \
  -e "s|^PRIORITY=.*|PRIORITY=15|" \
  -e "s|^ZL2R=.*|ZL2R=true|" \
  -e "s|^LOG_DISK_SIZE=.*|LOG_DISK_SIZE=${LOG_DISK}|" \
  -e "s|^COMP_ALG=.*|COMP_ALG=${ZRAM_ALGO}|" \
  /etc/log2ram.conf

# Trixie's log2ram 1.7.2 ships fewer keys in the default conf — sed
# substitutions silently no-op on missing keys. Append any that didn't get set.
ensure_kv() {
  local key=$1 val=$2
  if ! grep -qE "^${key}=" /etc/log2ram.conf; then
    echo "${key}=${val}" >> /etc/log2ram.conf
  fi
}
ensure_kv USE_RSYNC true
ensure_kv MAIL false
ensure_kv PRIORITY 15

# Same package also ships a duplicate JOURNALD_AWARE=true line. Harmless
# (last assignment wins) but confusing in diffs — drop the dupe.
awk '!seen[$0]++ || $0 !~ /^JOURNALD_AWARE=/' /etc/log2ram.conf > /etc/log2ram.conf.tmp \
  && mv /etc/log2ram.conf.tmp /etc/log2ram.conf

# Override the daily sync timer to run hourly (less data lost on power failure)
mkdir -p /etc/systemd/system/log2ram-daily.timer.d
cat > /etc/systemd/system/log2ram-daily.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
EOF

systemctl daemon-reload
systemctl enable log2ram
systemctl enable log2ram-daily.timer

# ---------------------------------------------------------------------------
# 5. logrotate — keep /var/log small so RAM budget is safe
# ---------------------------------------------------------------------------
echo "==> Tuning logrotate"
[[ ! -f /etc/logrotate.conf.bak ]] && cp /etc/logrotate.conf /etc/logrotate.conf.bak

cat > /etc/logrotate.conf <<'EOF'
# Tuned by ramdisk-logging.sh for RAM-backed /var/log
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

# Run logrotate hourly instead of daily
if [[ -f /etc/cron.daily/logrotate && ! -f /etc/cron.hourly/logrotate ]]; then
  mv /etc/cron.daily/logrotate /etc/cron.hourly/logrotate
fi

# ---------------------------------------------------------------------------
# 6. journald — persistent journal under /var/log so log2ram can zram-buffer it
# ---------------------------------------------------------------------------
echo "==> Tuning systemd-journald for persistent journal via log2ram"

# Raspberry Pi OS Bookworm/Trixie may ship vendor drop-ins under
# /usr/lib/systemd/journald.conf.d/, including:
#   40-rpi-volatile-storage.conf -> Storage=volatile
#   syslog.conf                  -> ForwardToSyslog=yes
#
# Do not edit vendor files. Override them from /etc with a later-numbered
# drop-in so package updates do not undo our change.
mkdir -p /etc/systemd/journald.conf.d/

cat > /etc/systemd/journald.conf.d/50-log2ram-zram-persistent-override.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
EOF

# Required for Storage=persistent. With log2ram active after reboot, this path
# should live under the RAM/zram-backed /var/log mount and get synced to disk
# by log2ram's timer.
mkdir -p /var/log/journal

systemctl restart systemd-journald || true

# ---------------------------------------------------------------------------
# 7. noatime on root mount — stops access-time writes on every file read
# ---------------------------------------------------------------------------
echo "==> Adding noatime to root mount"
if ! awk '$2 == "/" {print $4}' /etc/fstab | grep -q noatime; then
  [[ ! -f /etc/fstab.bak ]] && cp /etc/fstab /etc/fstab.bak
  # Append ,noatime to the options column of the / mount line
  sed -i -E '/^\S+\s+\/\s+\S+\s+/{s|(^\S+\s+/\s+\S+\s+)(\S+)|\1\2,noatime|}' /etc/fstab
fi

# ---------------------------------------------------------------------------
# 8. sysctl tuning — tune swappiness and cache pressure for zram-heavy setup
# ---------------------------------------------------------------------------
echo "==> Writing sysctl tuning for zram"
cat > /etc/sysctl.d/99-pi-sd-saver.conf <<EOF
# Tuned by ramdisk-logging.sh for ${PI_MODEL}
# zram is fast compressed RAM — push pages to it aggressively rather
# than reclaiming page cache.
vm.swappiness=${VM_SWAPPINESS}

# Reduce pressure to reclaim dentry/inode caches, which are cheap in RAM
# and expensive to rebuild from the SD card.
vm.vfs_cache_pressure=${VM_VFS_CACHE_PRESSURE}
EOF
sysctl --quiet --load=/etc/sysctl.d/99-pi-sd-saver.conf || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<'EOM'

==============================================================
  Setup complete. A reboot is required for everything to apply.
==============================================================

Reboot:
    sudo reboot

After reboot, verify with:
    zramctl                         # zram devices: swap + log2ram
    swapon --show                   # should show /dev/zram0 swap
    df -h /var/log /tmp             # both should be tmpfs / zram-backed
    systemctl status log2ram
    systemctl list-timers | grep log2ram
    systemd-analyze cat-config systemd/journald.conf
    sudo find /run/log/journal /var/log/journal -type f -name "*.journal*" -printf '%p\n' 2>/dev/null
    journalctl --list-boots
    journalctl -u log2ram --no-pager --since today
    free -h
    mount | grep -E '/(tmp|var/log|)\s'
    sysctl vm.swappiness vm.vfs_cache_pressure

Backups / new files (delete or restore to revert):
    /etc/default/zramswap.bak                    (zram-tools path)
    /etc/systemd/zram-generator.conf.bak         (systemd-zram-generator path)
    /etc/rpi/swap.conf.d/99-pi-sd-saver.conf     (rpi-swap path — delete to revert)
    /etc/log2ram.conf.bak
    /etc/logrotate.conf.bak
    /etc/systemd/journald.conf.d/50-log2ram-zram-persistent-override.conf
    /etc/fstab.bak
    /etc/sysctl.d/99-pi-sd-saver.conf            (delete to revert sysctl tuning)

Tuning tips:
 - If 'df -h /var/log' shows >80% after a week, bump SIZE in
   /etc/log2ram.conf and/or tighten logrotate maxsize.
 - If swap is never used, drop PERCENT in /etc/default/zramswap.
 - For a clean uninstall:
     sudo apt purge log2ram zram-tools
     # then restore .bak files and reboot.

EOM