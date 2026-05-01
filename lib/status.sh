#!/bin/bash

# lib/status.sh - Status file helpers for installicious.
#
# Status files live under $PATH_STATUS as <id>.status. They are bash-sourceable:
# each line is KEY="value". This library provides:
#   - Atomic single-key updates (write-temp + mv -f, no partial-write window)
#   - Atomic full-file rewrites
#   - Read helpers (no env pollution)
#   - A skip-decision helper based on a recorded version + config-file hash
#
# Framework metadata schema. Each installer's status file may include framework
# fields prefixed with the uppercased installer id and "_FW_". Example for
# installer id "pkupd":
#   PKUPD_FW_STATE="completed"     # pending|running|completed|failed|reboot-pending
#   PKUPD_FW_VERSION="2"
#   PKUPD_FW_CONFIG_HASH="abc123..."
#   PKUPD_FW_STARTED_AT="YYYY-MM-DD HH:MM:SS"
#   PKUPD_FW_FINISHED_AT="YYYY-MM-DD HH:MM:SS"
#   PKUPD_FW_LAST_ERROR=""
# Installers remain free to add their own keys (e.g. PKUPD_UPDATE) alongside.
# The id-prefix means multiple status files can be sourced in the same shell
# without key collisions, matching the existing convention.

# status_file_for <id> -> echoes the status-file path for an installer id.
status_file_for() {
  local id="$1"
  local path_status="${PATH_STATUS:-status}"
  echo "${path_status}/${id}.status"
}

# status_get <file> <key> -> echoes the value of key in the file (empty if missing).
# Sources the file in a subshell so the caller's env is not polluted.
status_get() {
  local file="$1"
  local key="$2"
  if [[ ! -f $file ]]; then
    return 0
  fi
  (
    # shellcheck disable=SC1090
    source "$file" 2>/dev/null
    echo "${!key}"
  )
}

# status_set <file> <key> <value> - atomic single-key update.
# Creates the file if missing, replaces the key if present, appends if not.
status_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local dir
  dir=$(dirname "$file")
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir" || return 1
  fi
  local tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if [[ -f $file ]]; then
    grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  fi
  printf '%s="%s"\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$file"
}

# status_write_atomic <file> - write content from stdin to file atomically.
status_write_atomic() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir" || return 1
  fi
  local tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  cat > "$tmp"
  mv -f "$tmp" "$file"
}

# config_hash <config_file> -> sha256 of a config file (empty if missing).
config_hash() {
  local file="$1"
  if [[ ! -f $file ]]; then
    echo ""
    return 0
  fi
  sha256sum "$file" | awk '{print $1}'
}

# status_should_skip <id> <expected_version> [config_file]
# Returns 0 (skip) if the recorded state is "completed" AND the recorded version
# matches expected_version AND (if config_file given) the recorded config hash
# matches the current hash of config_file. Otherwise returns 1 (run).
status_should_skip() {
  local id="$1"
  local expected_version="$2"
  local config_file="$3"
  local file
  file=$(status_file_for "$id")
  if [[ ! -f $file ]]; then
    return 1
  fi
  local prefix="${id^^}_FW_"
  local state version recorded_hash current_hash
  state=$(status_get "$file" "${prefix}STATE")
  if [[ $state != "completed" ]]; then
    return 1
  fi
  if [[ -n $expected_version ]]; then
    version=$(status_get "$file" "${prefix}VERSION")
    if [[ $version != "$expected_version" ]]; then
      return 1
    fi
  fi
  if [[ -n $config_file ]]; then
    recorded_hash=$(status_get "$file" "${prefix}CONFIG_HASH")
    current_hash=$(config_hash "$config_file")
    if [[ $recorded_hash != "$current_hash" ]]; then
      return 1
    fi
  fi
  return 0
}

# status_mark_started <id> - record framework state=running, set STARTED_AT, clear LAST_ERROR.
status_mark_started() {
  local id="$1"
  local file prefix ts
  file=$(status_file_for "$id")
  prefix="${id^^}_FW_"
  ts=$(date '+%Y-%m-%d %T.%5N')
  status_set "$file" "${prefix}STATE" "running"
  status_set "$file" "${prefix}STARTED_AT" "$ts"
  status_set "$file" "${prefix}LAST_ERROR" ""
}

# status_mark_complete <id> <version> [config_file]
# Records framework state=completed, version, config hash, FINISHED_AT.
status_mark_complete() {
  local id="$1"
  local version="$2"
  local config_file="$3"
  local file prefix ts hash
  file=$(status_file_for "$id")
  prefix="${id^^}_FW_"
  ts=$(date '+%Y-%m-%d %T.%5N')
  hash=$(config_hash "$config_file")
  status_set "$file" "${prefix}STATE" "completed"
  status_set "$file" "${prefix}VERSION" "$version"
  status_set "$file" "${prefix}CONFIG_HASH" "$hash"
  status_set "$file" "${prefix}FINISHED_AT" "$ts"
}

# status_mark_failed <id> [error_message]
status_mark_failed() {
  local id="$1"
  local err="$2"
  local file prefix ts
  file=$(status_file_for "$id")
  prefix="${id^^}_FW_"
  ts=$(date '+%Y-%m-%d %T.%5N')
  status_set "$file" "${prefix}STATE" "failed"
  status_set "$file" "${prefix}FINISHED_AT" "$ts"
  status_set "$file" "${prefix}LAST_ERROR" "$err"
}

# status_mark_reboot_pending <id> [reason]
status_mark_reboot_pending() {
  local id="$1"
  local reason="$2"
  local file prefix
  file=$(status_file_for "$id")
  prefix="${id^^}_FW_"
  status_set "$file" "${prefix}STATE" "reboot-pending"
  status_set "$file" "${prefix}LAST_ERROR" "$reason"
}
