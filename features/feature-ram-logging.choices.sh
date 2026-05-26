# features/feature-ram-logging.choices.sh
#
# Menu choices + smart defaults for feature-ram-logging.
#
# RAMLOG_PROFILE: single radio across the 4 sync × 2 backend matrix.
# Internal value is `<backend>-<sync>` so the installer body can split
# on `-` to extract backend (tmpfs/zram) and sync (volatile/shutdown/
# periodic/both) without juggling two separate config keys.

source lib/pi-tier.sh

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

# Auto-tune the /var/log RAM area size based on installed RAM, via the
# shared pi_tier_size_for helper. Buckets (small/mid/large/xl) map to:
#   small (Pi Zero / Pi 3 / <= 1 GB)         -> 48  MB
#   mid   (Pi 4 2GB / 1-3 GB)                -> 128 MB
#   large (Pi 4 4GB / 3-6 GB)                -> 256 MB
#   xl    (Pi 5 / Pi 4 8GB / > 6 GB)         -> 256 MB
# Collapsed large+xl to 256 MB: /var/log doesn't benefit from more than
# that on any current Pi, and growing it past 256 MB needlessly chews
# into RAM the system can use elsewhere.
_default_RAMLOG_SIZE_MB() {
  pi_tier_size_for "48 128 256 256"
}

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
  pi_cpu_choice "zstd lz4"
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
