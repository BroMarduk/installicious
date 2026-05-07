# features/feature-ram-logging.choices.sh
#
# Menu choices + smart defaults for feature-ram-logging.
#
# RAMLOG_PROFILE: single radio across the 4 sync × 2 backend matrix.
# Internal value is `<backend>-<sync>` so the installer body can split
# on `-` to extract backend (tmpfs/zram) and sync (volatile/shutdown/
# periodic/both) without juggling two separate config keys.

_choices_RAMLOG_PROFILE() {
  cat <<'EOF'
tmpfs-volatile	Uncompressed Volatile (tmpfs, no sync)
tmpfs-shutdown	Uncompressed Save on Shutdown (tmpfs, sync at poweroff)
tmpfs-periodic	Uncompressed Save Periodically (tmpfs, hourly sync)
tmpfs-both	Uncompressed Save Both (tmpfs, hourly + on shutdown)
zram-volatile	Compressed Volatile (ZRAM, no sync)
zram-shutdown	Compressed Save on Shutdown (ZRAM, sync at poweroff)
zram-periodic	Compressed Save Periodically (ZRAM, hourly sync)
zram-both	Compressed Save Both (ZRAM, hourly + on shutdown)
EOF
}

_default_RAMLOG_PROFILE() {
  echo "zram-both"
}

# Auto-tune the /var/log RAM area size based on installed RAM. Lifted
# from scripts/ramdisk-logging.sh's table:
#   ≥ 3.5 GB (Pi 4 4GB+ / Pi 5)              -> 256 MB
#   1.8 - 3.5 GB (Pi 4 2GB / CM4 2GB)         -> 128 MB
#   < 1.8 GB (Pi 3 / Zero 2 W / 3A+ / older) -> 48  MB
_default_RAMLOG_SIZE_MB() {
  [[ -r /proc/meminfo ]] || { echo 128; return 0; }
  local ram_mb
  ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  [[ -z $ram_mb ]] && { echo 128; return 0; }
  if   (( ram_mb >= 3500 )); then echo 256
  elif (( ram_mb >= 1800 )); then echo 128
  else                            echo 48
  fi
}

# Same per-Pi-CPU logic as feature-compressed-swap.choices.sh — the
# choice is a CPU-class characteristic, not a swap-vs-logs concern.
# Pi 4 / 5 / CM4 / Pi 400 (Cortex-A72/A76) handle zstd's better ratio
# without breaking a sweat. Older Cortex-A53 and ARMv6 cores get
# bottlenecked on zstd; lz4 is ~3x faster there for a small ratio
# penalty.
_choices_RAMLOG_COMPRESSION_ALGO() {
  cat <<'EOF'
zstd	zstd (best ratio; recommended on Pi 4 / 5)
lz4	lz4  (lighter on CPU; recommended on Pi 3 / Zero 2)
EOF
}

_default_RAMLOG_COMPRESSION_ALGO() {
  [[ -r /proc/device-tree/model ]] || { echo zstd; return 0; }
  local pi_model
  pi_model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
  case "$pi_model" in
    *"Pi 5"*|*"Pi 4"*|*"Compute Module 4"*|*"Pi 400"*) echo zstd ;;
    *"Pi 3"*|*"Pi 2"*|*"Zero 2"*|*"Compute Module 3"*|*"Pi Zero"*|*"Pi Model"*) echo lz4 ;;
    *) echo lz4 ;;
  esac
}

# RAMLOG_COMPRESSION_ALGO is irrelevant on a tmpfs-backed profile —
# tmpfs has no compression. Hide it from the editor when the user has
# picked a tmpfs profile so the menu doesn't suggest a meaningless
# choice. _applies_<KEY> takes precedence over _choices_/_default_, per
# lib/menu.sh's contract.
_applies_RAMLOG_COMPRESSION_ALGO() {
  # Read RAMLOG_PROFILE the same way menu_edit_config does — it's
  # already been sourced from the config chain by the time helpers
  # run. Default to zram if unset.
  case "${RAMLOG_PROFILE:-zram-both}" in
    zram-*) return 0 ;;
    *) return 1 ;;
  esac
}
