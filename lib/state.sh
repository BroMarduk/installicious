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

# _state_read_field <var> <file>
# Echo the value of a single II_QUEUE_* variable from a state file by
# sourcing it in an isolated subshell. One field per call — deliberately
# NOT a tab-joined multi-field read: tab is an IFS *whitespace* character,
# so a `printf '%s\t%s\t...'` of fields where some are empty collapses the
# run of adjacent tabs into a single delimiter, and the non-empty values
# shift left into the wrong variables. (That bug swapped II_QUEUE_REASON
# and II_QUEUE_STARTED_AT on every queue.) Per-field subshells have no
# delimiter to collapse, so empty fields stay put.
_state_read_field() {
  local var="$1" file="$2"
  (
    # shellcheck disable=SC1090
    source "$file" 2>/dev/null
    printf '%s' "${!var:-}"
  )
}

# state_save_cursor <cursor>
# Update only the cursor; preserves the rest of the state file.
state_save_cursor() {
  local cursor="$1"
  local file
  file=$(_state_file)
  if [[ ! -f $file ]]; then
    # No state file yet — nothing meaningful to do.
    return 1
  fi
  local ids reason trigger started_at
  ids=$(_state_read_field II_QUEUE_IDS "$file")
  reason=$(_state_read_field II_QUEUE_REASON "$file")
  trigger=$(_state_read_field II_QUEUE_TRIGGER "$file")
  started_at=$(_state_read_field II_QUEUE_STARTED_AT "$file")
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
    ids=$(_state_read_field II_QUEUE_IDS "$file")
    started_at=$(_state_read_field II_QUEUE_STARTED_AT "$file")
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
# Config overrides — two layers
#
# An installer that advertises editable config (II_EDITABLE_CONFIG) sources
# its baseline config/*.config files, then calls state_apply_menu_overrides
# to layer two user-override files on top (lowest precedence first):
#
#   1. overrides/configuration.override  — hand-authored by the user. A
#      plain KEY=VALUE bash file for setting preferred DEFAULTS without
#      clicking through the in-menu editor. Drop one onto a fresh Pi and
#      every install picks up your values — repeatability, no re-typing.
#      Gitignored (*.override) and skipped by setup.sh's rsync, so it
#      persists across re-downloads.
#
#   2. $PATH_STATE/menu-config.sh         — machine-written by
#      menu_edit_config when the user edits values on the in-menu screen.
#      Sourced LAST, so an in-menu edit always wins over the hand-authored
#      configuration.override (the file is your baseline; the menu tweaks
#      on top).
#
# Net precedence:  config/*.config  <  configuration.override  <  menu-config.sh
#
# menu-config.sh lifecycle: NOT cleared automatically.
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

# _config_override_file - path to the hand-authored overrides file.
_config_override_file() {
  echo "${PATH_OVERRIDES:-overrides}/configuration.override"
}

# state_apply_menu_overrides - layer the user-override files onto the
# config values already sourced by the caller. Sources, in order:
#   1. overrides/configuration.override  (hand-authored baseline)
#   2. $PATH_STATE/menu-config.sh         (in-menu editor output — wins)
# Each is a no-op if its file doesn't exist. Call from an installer after
# its baseline config/*.config sourcing.
state_apply_menu_overrides() {
  local cfg_override
  cfg_override=$(_config_override_file)
  if [[ -f $cfg_override ]]; then
    # shellcheck disable=SC1090
    source "$cfg_override"
  fi
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

# ---------------------------------------------------------------------------
# Picker selections (last-run memory)
#
# Persists the user's picker choices to $PATH_STATE/selections.sh so a
# subsequent run defaults to what they picked last time — covers the role
# pick, the role-tier picks (step 4a + 4b), the addons map, packages, and
# the custom-flow feature checklist. Distinct from menu-config.sh (which
# stores edited config VALUES); this stores which features/packages/add-ons
# were CHECKED.
#
# Schema:
#   LAST_ROLE_ID="weewx"                       # last-picked role
#   LAST_FEATURES_SELECTED=""                  # custom-flow picks
#   LAST_ROLE_SPECIFIC_PICKED="weewx-setup …"  # step 4a picks
#   LAST_OPTIONAL_PICKED="compressed-swap …"   # step 4b picks
#   LAST_PACKAGES_SELECTED=""                  # step 6 picks
#   LAST_ADDONS_PICKED="webserver:webserver-ssl;motd:motd-weather,motd-updates"
#     # serialized addons map — `;` separates entries, `:` splits
#     # parent from children, `,` separates children within a parent.
#     # Feature IDs in this codebase don't contain `;` `:` or `,` so the
#     # encoding is unambiguous without escaping.
#
# Lifecycle: the file is overwritten on every picker advance, persists
# across runs and a Cancel-mid-flow, and is NOT auto-cleared. Manual reset:
#   sudo rm $PATH_STATE/selections.sh
# ---------------------------------------------------------------------------

_selections_file() {
  echo "${PATH_STATE:-state}/selections.sh"
}

# state_load_selections - source $PATH_STATE/selections.sh if present,
# populating LAST_* variables in the caller's env. rc=0 if loaded, rc=1
# if no file exists. Caller should treat all LAST_* as optional ("${var:-}").
state_load_selections() {
  local file
  file=$(_selections_file)
  if [[ ! -f $file ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$file"
}

# state_save_selections <role> <features> <role_specific> <optional> <packages> <addons_serialized>
# Overwrite the selections file with the given values. Each arg is the
# space-separated picker output; addons_serialized is the
# parent:children;parent:children format documented at the top of this section.
state_save_selections() {
  local role="${1:-}"
  local features="${2:-}"
  local role_specific="${3:-}"
  local optional="${4:-}"
  local packages="${5:-}"
  local addons="${6:-}"
  _state_write_pairs "$(_selections_file)" \
    "LAST_ROLE_ID=$role" \
    "LAST_FEATURES_SELECTED=$features" \
    "LAST_ROLE_SPECIFIC_PICKED=$role_specific" \
    "LAST_OPTIONAL_PICKED=$optional" \
    "LAST_PACKAGES_SELECTED=$packages" \
    "LAST_ADDONS_PICKED=$addons"
}

# state_clear_selections - remove the selections file. Called by manual
# reset paths (or a future --reset-selections flag); never invoked by the
# framework's normal flow.
state_clear_selections() {
  local file
  file=$(_selections_file)
  [[ -f $file ]] || return 0
  rm -f "$file" 2>/dev/null || sudo rm -f "$file"
}
