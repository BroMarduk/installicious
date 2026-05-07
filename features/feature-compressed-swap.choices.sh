# features/feature-zram.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config and by
# the feature-zram installer body. Sourced automatically when feature-zram
# contributes editable keys.
#
# _default_<KEY>() returns the smart default for KEY when the static
# config (config/zram.config) leaves it blank. The same helper is also
# called by feature-zram.sh at install time so the editor display and
# the actual configuration stay in lock-step.
#
# Logic lifted from scripts/ramdisk-logging.sh:
#   - Compression algo: lz4 on older Cortex-A53 / ARMv6 Pis (CPU is the
#     bottleneck; lz4 is ~3x faster than zstd at compression). zstd on
#     Cortex-A72/A76 (Pi 4 / 5 / CM4) where the better ratio wins.
#   - Swap percentage: 50% on roomy Pis (≥1.8 GB), 40% on tight-RAM
#     Pis (<1.8 GB) so we don't crowd out actual workload.

_default_ZRAM_COMPRESSION_ALGO() {
  [[ -r /proc/device-tree/model ]] || { echo zstd; return 0; }
  local pi_model
  pi_model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
  case "$pi_model" in
    *"Pi 5"*|*"Pi 4"*|*"Compute Module 4"*|*"Pi 400"*)
      echo zstd
      ;;
    *"Pi 3"*|*"Pi 2"*|*"Zero 2"*|*"Compute Module 3"*|*"Pi Zero"*|*"Pi Model"*)
      echo lz4
      ;;
    *)
      # Unknown / future hardware — err toward lz4 (universally supported,
      # lighter on CPU; modest ratio penalty).
      echo lz4
      ;;
  esac
}

_default_ZRAM_PERCENT_OF_RAM() {
  [[ -r /proc/meminfo ]] || { echo 50; return 0; }
  local ram_mb
  ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  [[ -z $ram_mb ]] && { echo 50; return 0; }
  if (( ram_mb >= 1800 )); then
    echo 50
  else
    # Tight RAM (Pi 3 / Zero 2 W / 3A+): leave more headroom for the
    # actual workload — over-aggressive zram swap on these can thrash.
    echo 40
  fi
}

_default_ZRAM_SWAP_PRIORITY() {
  # Static — no hardware-dependent reason to change. Defined here so the
  # editor screen has a value to show for it too when config is blank.
  echo 100
}
