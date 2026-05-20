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

# config_hash <file>... -> sha256 over the given config/override file(s)
# PLUS the two global config-override layers. Empty string if nothing
# exists. Missing files are silently skipped.
#
# Every call also folds in, after the caller's files:
#   overrides/configuration.override   hand-authored editable-config defaults
#   $PATH_STATE/menu-config.sh         the in-menu editor's output
# so a change to ANY input — a config file, an installer's own override
# file (e.g. overrides/weewx.override) passed by the caller, the
# configuration.override, or a menu edit — flips the hash and makes
# status_should_skip re-run the installer.
#
# Slightly over-eager (touching any key re-runs every installer that
# hashes config) but the re-runs are idempotent, and that beats
# per-installer "which keys do I care about" bookkeeping.
config_hash() {
  local input="" f
  for f in "$@" \
           "${PATH_OVERRIDES:-overrides}/configuration.override" \
           "${PATH_STATE:-state}/menu-config.sh"; do
    [[ -n $f && -f $f ]] || continue
    input+="--- $f ---"$'\n'
    input+="$(cat "$f")"$'\n'
  done
  if [[ -z $input ]]; then
    echo ""
    return 0
  fi
  printf '%s' "$input" | sha256sum | awk '{print $1}'
}

# _status_var_prefix <id> -> echo "<UPPER>_FW_" with dashes translated to
# underscores. Bash variable names cannot contain `-`, so installer IDs like
# "motd-weather" must become "MOTD_WEATHER_FW_" (NOT "MOTD-WEATHER_FW_") for
# any subsequent ${!key} indirect read to work.
_status_var_prefix() {
  local id="$1"
  local up="${id^^}"
  echo "${up//-/_}_FW_"
}

# status_state <id> -> echo current FW state ("completed", "running", "failed",
# "uninstalled", "reboot-pending"); empty if no status file or key.
status_state() {
  local id="$1"
  local file prefix
  file=$(status_file_for "$id")
  prefix=$(_status_var_prefix "$id")
  status_get "$file" "${prefix}STATE"
}

# status_should_skip <id> <expected_version> [<config_file>...]
# Returns 0 (skip) if the recorded state is "completed" AND the recorded
# version matches expected_version AND (if any non-empty config_file is
# given) the recorded config hash still matches config_hash over those
# files. Otherwise returns 1 (run).
#
# Pass every file whose contents should re-trigger this installer — its
# config/<id>.config AND any override file it consumes (e.g.
# overrides/weewx.override). config_hash additionally folds in the global
# configuration.override + menu-config.sh layers, so a change to any of
# them busts the skip too.
status_should_skip() {
  local id="$1"
  local expected_version="$2"
  shift 2
  local file
  file=$(status_file_for "$id")
  if [[ ! -f $file ]]; then
    return 1
  fi
  local prefix
  prefix=$(_status_var_prefix "$id")
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
  # Hash-check only when the caller passed at least one non-empty file
  # path (matches the historical "config_file given?" gate).
  local have_files=0 a
  for a in "$@"; do
    [[ -n $a ]] && have_files=1
  done
  if [[ $have_files -eq 1 ]]; then
    recorded_hash=$(status_get "$file" "${prefix}CONFIG_HASH")
    current_hash=$(config_hash "$@")
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
  prefix=$(_status_var_prefix "$id")
  ts=$(date '+%Y-%m-%d %T.%5N')
  status_set "$file" "${prefix}STATE" "running"
  status_set "$file" "${prefix}STARTED_AT" "$ts"
  status_set "$file" "${prefix}LAST_ERROR" ""
}

# status_mark_complete <id> <version> [<config_file>...]
# Records framework state=completed, version, config hash, FINISHED_AT.
# Pass the SAME file list given to status_should_skip so the recorded
# hash and the next run's comparison hash line up.
status_mark_complete() {
  local id="$1"
  local version="$2"
  shift 2
  local file prefix ts hash
  file=$(status_file_for "$id")
  prefix=$(_status_var_prefix "$id")
  ts=$(date '+%Y-%m-%d %T.%5N')
  hash=$(config_hash "$@")
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
  prefix=$(_status_var_prefix "$id")
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
  prefix=$(_status_var_prefix "$id")
  status_set "$file" "${prefix}STATE" "reboot-pending"
  status_set "$file" "${prefix}LAST_ERROR" "$reason"
}

# status_mark_uninstalled <id>
# Records that the installer has been reverted. The status file is preserved
# as an audit trail (with state=uninstalled and a fresh FINISHED_AT).
status_mark_uninstalled() {
  local id="$1"
  local file prefix ts
  file=$(status_file_for "$id")
  prefix=$(_status_var_prefix "$id")
  ts=$(date '+%Y-%m-%d %T.%5N')
  status_set "$file" "${prefix}STATE" "uninstalled"
  status_set "$file" "${prefix}FINISHED_AT" "$ts"
  status_set "$file" "${prefix}LAST_ERROR" ""
}
