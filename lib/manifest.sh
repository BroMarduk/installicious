#!/bin/bash

# lib/manifest.sh - Installer manifest extraction & registry helpers.
#
# Each installer carries a fenced, sourceable manifest block at the top of the
# file:
#
#   # === II_MANIFEST_BEGIN ===
#   II_ID="git"
#   II_TITLE="Git source control"
#   II_CATEGORY="software"            # software | option
#   II_VERSION="1"
#   II_DEPS=""                        # space-separated installer IDs
#   II_REQUIRES_REBOOT="never"        # never | conditional | always
#   # === II_MANIFEST_END ===
#
# These vars are sourced by the installer at runtime AND by the orchestrator
# (without executing the installer body) via the helpers here.
#
# Usage:
#   source lib/manifest.sh
#   manifest_extract       <file>             # echo just the manifest block content
#   manifest_get_field     <file> <field>     # echo a single field value
#   manifest_list_files    [<dir>]            # list installer paths in dir
#   manifest_list_ids      [<dir>]            # list IDs from valid manifests
#   manifest_filter_by_category <cat> [<dir>] # list IDs matching category
#
# Default <dir> is "$PATH_INSTALLERS" if set, otherwise "installers".

_manifest_default_dir() {
  echo "${PATH_INSTALLERS:-installers}"
}

# manifest_extract <file> -> echo the manifest block content (between sentinels).
# Output is empty if the file lacks the sentinels.
manifest_extract() {
  local file="$1"
  [[ -f $file ]] || return 0
  awk '
    /^# === II_MANIFEST_BEGIN ===/ {flag=1; next}
    /^# === II_MANIFEST_END ===/   {flag=0}
    flag                            {print}
  ' "$file"
}

# manifest_get_field <file> <field> -> echo the value of a single manifest field.
# Empty if file or field is missing. Sources the block in a subshell so the
# caller's environment is not mutated.
manifest_get_field() {
  local file="$1"
  local field="$2"
  local block
  block=$(manifest_extract "$file")
  [[ -z $block ]] && return 0
  (
    # shellcheck disable=SC2086
    eval "$block"
    echo "${!field}"
  )
}

# manifest_list_files [<dir>] -> list installer-script paths (one per line).
manifest_list_files() {
  local dir="${1:-$(_manifest_default_dir)}"
  [[ -d $dir ]] || return 0
  local f
  for f in "$dir"/install-*.sh; do
    [[ -f $f ]] && echo "$f"
  done
}

# manifest_list_ids [<dir>] -> list IDs of installers that have a valid manifest.
manifest_list_ids() {
  local dir="${1:-$(_manifest_default_dir)}"
  local f id
  while IFS= read -r f; do
    id=$(manifest_get_field "$f" "II_ID")
    [[ -n $id ]] && echo "$id"
  done < <(manifest_list_files "$dir")
}

# manifest_path_for <id> [<dir>] -> echo the installer-script path for a given ID.
# Empty (and rc=1) if not found.
manifest_path_for() {
  local id="$1"
  local dir="${2:-$(_manifest_default_dir)}"
  local f manifest_id
  while IFS= read -r f; do
    manifest_id=$(manifest_get_field "$f" "II_ID")
    if [[ $manifest_id == "$id" ]]; then
      echo "$f"
      return 0
    fi
  done < <(manifest_list_files "$dir")
  return 1
}

# manifest_filter_by_category <category> [<dir>] -> list IDs matching category.
manifest_filter_by_category() {
  local category="$1"
  local dir="${2:-$(_manifest_default_dir)}"
  local f id cat
  while IFS= read -r f; do
    cat=$(manifest_get_field "$f" "II_CATEGORY")
    if [[ $cat == "$category" ]]; then
      id=$(manifest_get_field "$f" "II_ID")
      [[ -n $id ]] && echo "$id"
    fi
  done < <(manifest_list_files "$dir")
}
