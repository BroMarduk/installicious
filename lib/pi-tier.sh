#!/bin/bash

# lib/pi-tier.sh — Pi hardware-class detection helpers.
#
# Two orthogonal axes:
#   pi_tier_size_for "<small> <mid> <large> <xl>" — RAM-tier bucket.
#   pi_cpu_choice    "<fast> <slow>"              — CPU-class bucket.
#
# Both take a space-separated value list and echo the value matching
# the detected Pi. Mirror signatures so callers compose them the same
# way ($(pi_tier_size_for "a b c d") / $(pi_cpu_choice "x y")).

# pi_tier_size_for "<small> <mid> <large> <xl>" — echo the value matching
# the detected Pi's RAM tier:
#   small  : Pi Zero / Pi Zero 2 / <= 1 GB total RAM
#   mid    : Pi 3 / Pi 4 (2GB) / 1-3 GB
#   large  : Pi 4 (4GB) / 3-6 GB
#   xl     : Pi 5 / Pi 4 (8GB) / > 6 GB
#
# Example:
#   pi_tier_size_for "64M 128M 256M 512M"
#
# Detection: prefer /proc/device-tree/model when present (Pi-specific
# string); fall back to total RAM from /proc/meminfo (works on
# non-Pi hardware too).

pi_tier_size_for() {
  local sizes="$1"
  local small mid large xl _rest
  # _rest absorbs any trailing tokens so a caller passing extras doesn't
  # poison `xl` with the leftover (read's default-IFS behaviour).
  read -r small mid large xl _rest <<< "$sizes"

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

# pi_cpu_choice "<fast> <slow>" — echo the value matching the detected
# Pi's CPU class:
#   fast  : Pi 4 / 5 / CM4 / Pi 400        (Cortex-A72 / A76)
#   slow  : Pi 3 / 2 / Zero / Zero 2 / CM3 (Cortex-A53 / ARMv6)
#
# Example:
#   pi_cpu_choice "zstd lz4"   # zstd on fast cores, lz4 on slow cores
#
# Edge cases preserve the inline-detection semantics this helper
# replaces:
#   /proc/device-tree/model unreadable -> "fast". Non-Pi host (dev
#     workstation, CI, generic x86) — assume a modern CPU that handles
#     the fast-class workload without trouble.
#   /proc/device-tree/model present but model not recognised -> "slow".
#     Unknown Pi could be older / weaker than what we've catalogued; the
#     slow value is the conservative pick (universally supported, lighter
#     on the CPU; modest ratio penalty for compression algos).

pi_cpu_choice() {
  local choices="$1"
  local fast slow _rest
  # _rest absorbs trailing tokens — see pi_tier_size_for for rationale.
  read -r fast slow _rest <<< "$choices"

  [[ -r /proc/device-tree/model ]] || { echo "$fast"; return 0; }
  local model
  model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)

  case "$model" in
    *"Pi 5"*|*"Pi 4"*|*"Compute Module 4"*|*"Pi 400"*) echo "$fast" ;;
    *"Pi 3"*|*"Pi 2"*|*"Zero 2"*|*"Compute Module 3"*|*"Pi Zero"*|*"Pi Model"*) echo "$slow" ;;
    *) echo "$slow" ;;
  esac
}
