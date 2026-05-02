#!/bin/bash

# lib/task.sh - Task manifest extraction & registry.
#
# A "task" is a Pi role (PiHole, WeeWx, Headless, etc.) — a bundle of
# installers + optional add-ons + task-specific config. The user picks one
# task, then the framework runs its required installers, plus any optional
# installers the user chose, all driven through the existing scheduler.
#
# Each task lives in $PATH_TASKS/task-<id>.sh with a fenced manifest block:
#
#   # === II_TASK_BEGIN ===
#   TASK_ID="pihole"
#   TASK_TITLE="Pi-Hole — DNS Sinkhole"
#   TASK_DESCRIPTION="Network-wide ad blocking via DNS server."
#   TASK_INSTALLERS_REQUIRED="pkupd rconf bash pihole-core"
#   TASK_INSTALLERS_OPTIONAL="ssh log2ram"
#   TASK_CONFIG="config/task-pihole.config"
#   TASK_EDITABLE_CONFIG="PIHOLE_WEB_PASSWORD PIHOLE_HOSTNAME"
#   # === II_TASK_END ===
#
# Helpers parallel lib/manifest.sh.

_task_default_dir() {
  echo "${PATH_TASKS:-tasks}"
}

# task_extract <file> -> echo the manifest block content (between sentinels).
task_extract() {
  local file="$1"
  [[ -f $file ]] || return 0
  awk '
    /^# === II_TASK_BEGIN ===/ {flag=1; next}
    /^# === II_TASK_END ===/   {flag=0}
    flag                        {print}
  ' "$file"
}

# task_get_field <file> <field> -> echo single field value.
# Sourced in a subshell to avoid polluting the caller's environment.
task_get_field() {
  local file="$1"
  local field="$2"
  local block
  block=$(task_extract "$file")
  [[ -z $block ]] && return 0
  (
    # shellcheck disable=SC2086
    eval "$block"
    echo "${!field}"
  )
}

# task_list_files [<dir>] -> list task-script paths.
task_list_files() {
  local dir="${1:-$(_task_default_dir)}"
  [[ -d $dir ]] || return 0
  local f
  for f in "$dir"/task-*.sh; do
    [[ -f $f ]] && echo "$f"
  done
}

# task_list_ids [<dir>] -> list IDs of tasks that have a valid manifest.
task_list_ids() {
  local dir="${1:-$(_task_default_dir)}"
  local f id
  while IFS= read -r f; do
    id=$(task_get_field "$f" "TASK_ID")
    [[ -n $id ]] && echo "$id"
  done < <(task_list_files "$dir")
}

# task_path_for <id> [<dir>] -> echo task-script path for an ID. rc=1 if not found.
task_path_for() {
  local id="$1"
  local dir="${2:-$(_task_default_dir)}"
  local f manifest_id
  while IFS= read -r f; do
    manifest_id=$(task_get_field "$f" "TASK_ID")
    if [[ $manifest_id == "$id" ]]; then
      echo "$f"
      return 0
    fi
  done < <(task_list_files "$dir")
  return 1
}
