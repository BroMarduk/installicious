#!/bin/bash

# lib/log.sh - Logging helpers for installicious.
#
# Format matches the long-standing convention used throughout installicious:
#   YYYY-MM-DD HH:MM:SS.NNNNN - LEVEL - [Module] Message[. Error Code: N.]
# Lines are written to stdout AND appended to the log file via tee, so this
# is a drop-in replacement for the existing
#   echo "$(date ...) - LEVEL - [$MODULE] msg" | sudo tee --append "$FILE_LOG_INSTALLER"
# pattern that is currently duplicated across every installer.
#
# Usage:
#   source lib/log.sh
#   log_init "Module Name" "$FILE_LOG_INSTALLER"
#   log_info "Started something"
#   log_warn "Something looks off" "$RET_VAL"   # error code is optional
#   log_fail "Something broke"     "$RET_VAL"
#   log_ok   "All done"

LIB_LOG_MODULE="${LIB_LOG_MODULE:-installicious}"
LIB_LOG_FILE="${LIB_LOG_FILE:-}"
# Default 1: use "sudo tee --append" (matches existing pattern; Pi log file is
# typically root-owned). Set to 0 in tests/dev where sudo is unavailable or the
# log file is user-writable.
LIB_LOG_USE_SUDO="${LIB_LOG_USE_SUDO:-1}"

log_init() {
  LIB_LOG_MODULE="$1"
  LIB_LOG_FILE="$2"
}

_log_emit() {
  local level="$1"
  local message="$2"
  local code="$3"
  local ts
  ts=$(date '+%Y-%m-%d %T.%5N')
  local suffix=""
  if [[ -n $code ]]; then
    suffix=" Error Code: $code."
  fi
  local line="${ts} - ${level} - [${LIB_LOG_MODULE}] ${message}${suffix}"
  if [[ -z $LIB_LOG_FILE ]]; then
    echo "$line"
    return
  fi
  if [[ $LIB_LOG_USE_SUDO == "1" ]]; then
    echo "$line" | sudo tee --append "$LIB_LOG_FILE"
  else
    echo "$line" | tee --append "$LIB_LOG_FILE"
  fi
}

log_info() { _log_emit "INFO" "$1" "$2"; }
log_warn() { _log_emit "WARN" "$1" "$2"; }
log_fail() { _log_emit "FAIL" "$1" "$2"; }
log_ok()   { _log_emit "OK"   "$1" "$2"; }
