#!/bin/bash

# lib/apt.sh - APT helpers for installicious.
#
# Provides timestamp-cached apt operations + idempotent install/remove.
# Absorbs the logic from functions/pkupd-software-check.sh and the apt cache
# logic in installers/install-pkupd.sh.
#
# Usage:
#   source lib/installicious.config + lib/log.sh + lib/status.sh + lib/apt.sh
#   apt_ensure_fresh                     # apt-get update if cache stale
#   apt_dist_upgrade_fresh               # apt-get dist-upgrade if cache stale
#   apt_autoremove_fresh                 # apt-get autoremove if cache stale
#   apt_ensure_installed git python3-pip # idempotent installs
#   apt_remove some-package              # purge + autoremove unused deps
#
# Configuration consumed (must be in scope, typically via installicious.config):
#   PATH_STATUS                - directory for status files
#   ACCEPTABLE_TIME_DELTA_SEC  - apt-cache lifetime in seconds. Default 0.
#
# Persistence: $PATH_STATUS/pkupd.status.time records the most recent run of
# each cached operation:
#   PKUPD_UPDATE_RUN
#   PKUPD_UPGRADE_RUN
#   PKUPD_AUTOREMOVE_RUN
#
# Requires lib/status.sh to be sourced first (uses status_get / status_set).

APT_TIME_FILE="${APT_TIME_FILE:-}"

_apt_time_file() {
  if [[ -n $APT_TIME_FILE ]]; then
    echo "$APT_TIME_FILE"
  else
    echo "${PATH_STATUS:-status}/pkupd.status.time"
  fi
}

# _apt_is_fresh <last_run_value> - return 0 if within ACCEPTABLE_TIME_DELTA_SEC.
_apt_is_fresh() {
  local last_run="$1"
  local delta="${ACCEPTABLE_TIME_DELTA_SEC:-0}"
  if [[ -z $last_run ]]; then
    return 1
  fi
  local now_unix last_unix age
  now_unix=$(date +%s)
  last_unix=$(date --date="$last_run" +%s 2>/dev/null) || return 1
  age=$((now_unix - last_unix))
  if (( age <= delta )); then
    return 0
  fi
  return 1
}

# _apt_run_with_cache <timestamp_key> <cmd> [args...]
# Runs cmd if the timestamp recorded under <timestamp_key> is older than
# ACCEPTABLE_TIME_DELTA_SEC (or absent). On success records a fresh timestamp.
# Returns 0 on success or skip, non-zero on cmd failure.
_apt_run_with_cache() {
  local key="$1"
  shift
  local time_file
  time_file=$(_apt_time_file)

  local last_run
  last_run=$(status_get "$time_file" "$key")
  if _apt_is_fresh "$last_run"; then
    return 0
  fi

  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  status_set "$time_file" "$key" "$(date '+%Y-%m-%d %T')"
}

# apt_ensure_fresh - run apt-get update if the cached run is stale.
apt_ensure_fresh() {
  _apt_run_with_cache "PKUPD_UPDATE_RUN" \
    sudo DEBIAN_FRONTEND="noninteractive" apt-get update --yes
}

# apt_dist_upgrade_fresh - run apt-get dist-upgrade if the cached run is stale.
apt_dist_upgrade_fresh() {
  _apt_run_with_cache "PKUPD_UPGRADE_RUN" \
    sudo DEBIAN_FRONTEND="noninteractive" apt-get dist-upgrade --yes
}

# apt_autoremove_fresh - run apt-get autoremove (with --purge) if the cached run is stale.
apt_autoremove_fresh() {
  _apt_run_with_cache "PKUPD_AUTOREMOVE_RUN" \
    sudo DEBIAN_FRONTEND="noninteractive" apt-get --yes --purge autoremove
}

# apt_is_installed <package> - return 0 if dpkg reports the package installed.
apt_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# apt_ensure_installed <package> [<package> ...]
# Install any not-yet-installed packages. Refreshes the apt cache first only if
# at least one package is missing.
apt_ensure_installed() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    if ! apt_is_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  apt_ensure_fresh || return $?
  sudo DEBIAN_FRONTEND="noninteractive" apt-get install --yes "${missing[@]}"
}

# apt_remove <package> [<package> ...] - purge packages and autoremove unused deps.
apt_remove() {
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  sudo DEBIAN_FRONTEND="noninteractive" apt-get --yes --purge autoremove "$@"
}
