#!/bin/bash

# lib/state.sh - Scheduler queue state for reboot/resume.
#
# Stores the in-flight queue at $PATH_STATE/queue.sh as a shell-sourceable
# file (no jq dependency). When set, the file means "there's work in progress
# that should resume on next boot". When the queue completes, the file is
# removed.
#
# Schema:
#   II_QUEUE_IDS="pkupd git pip zram"   # space-separated ordered queue
#   II_QUEUE_CURSOR=2                    # index of next item to run
#   II_QUEUE_REASON="rconf locale change"
#   II_QUEUE_TRIGGER="rconf"             # which installer asked for reboot
#   II_QUEUE_STARTED_AT="2026-05-01 09:00:00"
#
# Atomic via mktemp + mv -f. Same approach as lib/status.sh.
#
# Usage:
#   source lib/state.sh
#   state_save "git pip" 0 "" ""        # initial save at queue start
#   state_save_cursor 1                  # advance cursor only
#   state_save_reboot 1 "<reason>" "<trigger>"   # mark reboot-pending
#   state_load                           # source state file into env
#   state_exists                         # rc=0 if state file present
#   state_clear                          # remove state file (queue done)

_state_file() {
  echo "${PATH_STATE:-state}/queue.sh"
}

# Atomic write of a key=value file. Caller passes pairs as KEY=VALUE strings.
_state_write_pairs() {
  local file="$1"
  shift
  local dir
  dir=$(dirname "$file")
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir" || return 1
  fi
  local tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
  done
  mv -f "$tmp" "$file"
}

# state_save <ids> <cursor> [<reason>] [<trigger>]
# Initialize or fully replace the queue state. Records started_at as now.
state_save() {
  local ids="$1"
  local cursor="${2:-0}"
  local reason="${3:-}"
  local trigger="${4:-}"
  local started_at
  started_at=$(date '+%Y-%m-%d %T')
  _state_write_pairs "$(_state_file)" \
    "II_QUEUE_IDS=$ids" \
    "II_QUEUE_CURSOR=$cursor" \
    "II_QUEUE_REASON=$reason" \
    "II_QUEUE_TRIGGER=$trigger" \
    "II_QUEUE_STARTED_AT=$started_at"
}

# state_save_cursor <cursor>
# Update only the cursor; preserves the rest of the state file. Sources the
# existing file in a subshell to read the other fields.
state_save_cursor() {
  local cursor="$1"
  local file
  file=$(_state_file)
  if [[ ! -f $file ]]; then
    # No state file yet — nothing meaningful to do.
    return 1
  fi
  local ids reason trigger started_at
  read -r ids reason trigger started_at < <(
    # shellcheck disable=SC1090
    source "$file" 2>/dev/null
    printf '%s\t%s\t%s\t%s' \
      "${II_QUEUE_IDS:-}" "${II_QUEUE_REASON:-}" "${II_QUEUE_TRIGGER:-}" "${II_QUEUE_STARTED_AT:-}"
  )
  IFS=$'\t' read -r ids reason trigger started_at < <(
    # shellcheck disable=SC1090
    source "$file" 2>/dev/null
    printf '%s\t%s\t%s\t%s' \
      "${II_QUEUE_IDS:-}" "${II_QUEUE_REASON:-}" "${II_QUEUE_TRIGGER:-}" "${II_QUEUE_STARTED_AT:-}"
  )
  _state_write_pairs "$file" \
    "II_QUEUE_IDS=$ids" \
    "II_QUEUE_CURSOR=$cursor" \
    "II_QUEUE_REASON=$reason" \
    "II_QUEUE_TRIGGER=$trigger" \
    "II_QUEUE_STARTED_AT=$started_at"
}

# state_save_reboot <cursor> <reason> <trigger>
# Mark the queue as reboot-pending at the given cursor.
state_save_reboot() {
  local cursor="$1"
  local reason="$2"
  local trigger="$3"
  local file
  file=$(_state_file)
  local ids started_at
  if [[ -f $file ]]; then
    IFS=$'\t' read -r ids started_at < <(
      # shellcheck disable=SC1090
      source "$file" 2>/dev/null
      printf '%s\t%s' "${II_QUEUE_IDS:-}" "${II_QUEUE_STARTED_AT:-}"
    )
  fi
  [[ -z $started_at ]] && started_at=$(date '+%Y-%m-%d %T')
  _state_write_pairs "$file" \
    "II_QUEUE_IDS=$ids" \
    "II_QUEUE_CURSOR=$cursor" \
    "II_QUEUE_REASON=$reason" \
    "II_QUEUE_TRIGGER=$trigger" \
    "II_QUEUE_STARTED_AT=$started_at"
}

# state_load - source the state file into the caller's env.
# Returns rc=0 if state was loaded, rc=1 if no state file exists.
state_load() {
  local file
  file=$(_state_file)
  if [[ ! -f $file ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$file"
}

# state_exists - rc=0 if state file is present, else rc=1.
state_exists() {
  [[ -f "$(_state_file)" ]]
}

# state_clear - remove the state file (queue done).
state_clear() {
  local file
  file=$(_state_file)
  [[ -f $file ]] || return 0
  rm -f "$file" 2>/dev/null || sudo rm -f "$file"
}

# ---------------------------------------------------------------------------
# Menu config overrides
#
# When the user edits values in the menu_edit_config screen, we persist them
# to $PATH_STATE/menu-config.sh as a sourceable file. Each installer that
# advertises editable config (II_EDITABLE_CONFIG) sources this file AFTER its
# baseline .config files so the user's edits win — both at install time AND
# in future installicious sessions.
#
# Lifecycle: the file is intentionally NOT cleared automatically.
#   - Created/updated by menu_edit_config in both the forward and back paths
#     out of the editor (so in-progress edits survive a rewind-and-return).
#   - Persists across queue completion, queue failure, mid-queue reboots,
#     and brand-new sessions, so values like an AccuWeather API key only
#     have to be entered once.
#   - state_clear_menu_overrides() remains available for callers (or a
#     future --reset-config flag) that want to wipe the overrides; nothing
#     in the framework calls it on its own. Manual reset:
#       sudo rm $PATH_STATE/menu-config.sh
# ---------------------------------------------------------------------------

_menu_overrides_file() {
  echo "${PATH_STATE:-state}/menu-config.sh"
}

# state_apply_menu_overrides - source $PATH_STATE/menu-config.sh if present.
# Call from an installer after its baseline config sourcing so user-edited
# values override defaults. No-op if the file doesn't exist.
state_apply_menu_overrides() {
  local file
  file=$(_menu_overrides_file)
  if [[ -f $file ]]; then
    # shellcheck disable=SC1090
    source "$file"
  fi
}

# state_clear_menu_overrides - remove the override file.
state_clear_menu_overrides() {
  local file
  file=$(_menu_overrides_file)
  [[ -f $file ]] || return 0
  rm -f "$file" 2>/dev/null || sudo rm -f "$file"
}
