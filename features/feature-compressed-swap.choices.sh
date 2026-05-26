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

source lib/pi-tier.sh

_default_ZRAM_COMPRESSION_ALGO() {
  pi_cpu_choice "zstd lz4"
}

# Swap percentage by RAM tier (small/mid/large/xl) -> 40/50/50/50.
# Tight-RAM Pis (Pi 3 / Zero 2 W / 3A+) bucket as `small` and get 40%
# so we don't crowd out the actual workload — over-aggressive zram
# swap on these can thrash.
_default_ZRAM_PERCENT_OF_RAM() {
  pi_tier_size_for "40 50 50 50"
}

_default_ZRAM_SWAP_PRIORITY() {
  # Static — no hardware-dependent reason to change. Defined here so the
  # editor screen has a value to show for it too when config is blank.
  echo 100
}
