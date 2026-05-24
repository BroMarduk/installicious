#!/bin/bash

# lib/pi-tier.sh — Pi-RAM-tier detection.
#
# pi_tier_size_for "<small> <mid> <large> <xl>" — echo the tier value
# matching the detected Pi:
#   small  : Pi Zero / Pi Zero 2 / <= 1 GB total RAM
#   mid    : Pi 3 / Pi 4 (2GB) / 1-3 GB
#   large  : Pi 4 (4GB) / 3-6 GB
#   xl     : Pi 5 / Pi 4 (8GB) / > 6 GB
#
# Caller passes a space-separated list of four values mapped to those
# tiers, e.g.:
#   pi_tier_size_for "64M 128M 256M 512M"
#
# Detection: prefer /proc/device-tree/model when present (Pi-specific
# string); fall back to total RAM from /proc/meminfo (works on
# non-Pi hardware too).

pi_tier_size_for() {
  local sizes="$1"
  read -r small mid large xl <<< "$sizes"

  local model=""
  if [[ -r /proc/device-tree/model ]]; then
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
  fi

  case "$model" in
    *"Pi 5"*)       echo "$xl"; return ;;
    *"Pi Zero 2"*)  echo "$small"; return ;;
    *"Pi Zero"*)    echo "$small"; return ;;
  esac

  # Pi 4 ambiguity (1/2/4/8 GB variants) + everything else: use total RAM.
  local mem_kb mem_mb
  mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
  mem_mb=$(( mem_kb / 1024 ))

  if   (( mem_mb >= 6144 )); then echo "$xl"
  elif (( mem_mb >= 3072 )); then echo "$large"
  elif (( mem_mb >= 1280 )); then echo "$mid"
  else echo "$small"
  fi
}
