#!/bin/bash

# lib/manifest.sh - Manifest extraction & registry helpers across the feature
# and package tiers.
#
# Each feature or package script carries a fenced, sourceable manifest block
# at the top of the file:
#
#   # === II_MANIFEST_BEGIN ===
#   II_ID="git"
#   II_TITLE="Git source control"
#   II_CATEGORY="software"            # software | option
#   II_VERSION="1"
#   II_DEPS=""                        # space-separated IDs (any tier)
#   II_REQUIRES_REBOOT="never"        # never | conditional | always
#   # === II_MANIFEST_END ===
#
# These vars are sourced by the script at runtime AND by the orchestrator
# (without executing the body) via the helpers here.
#
# Usage:
#   source lib/manifest.sh
#   manifest_extract       <file>             # echo just the manifest block content
#   manifest_get_field     <file> <field>     # echo a single field value
#   manifest_list_files    [<dir>...]         # list manifest-bearing paths
#   manifest_list_ids      [<dir>...]         # list IDs from valid manifests
#   manifest_filter_by_category <cat> [<dir>...]
#
# With no <dir> args the helpers scan both default tier directories
# ($PATH_FEATURES + $PATH_PACKAGES); pass one or more dirs to scan only
# those (useful in tests). In any directory we accept files matching
# feature-*.sh OR package-*.sh — the prefix tells you the tier, the
# manifest's II_ID is the canonical reference.

_manifest_default_dirs() {
  echo "${PATH_FEATURES:-features}" "${PATH_PACKAGES:-packages}"
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

# manifest_list_files [<dir>...] -> list manifest-bearing paths (one per line).
# With no args, scans the default feature + package directories.
manifest_list_files() {
  local -a dirs=()
  if [[ $# -gt 0 ]]; then
    dirs=("$@")
  else
    # shellcheck disable=SC2207
    dirs=( $(_manifest_default_dirs) )
  fi
  local d f
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    for f in "$d"/feature-*.sh "$d"/package-*.sh; do
      [[ -f $f ]] && echo "$f"
    done
  done
}

# manifest_list_ids [<dir>...] -> list IDs that have a valid manifest.
manifest_list_ids() {
  local f id
  while IFS= read -r f; do
    id=$(manifest_get_field "$f" "II_ID")
    [[ -n $id ]] && echo "$id"
  done < <(manifest_list_files "$@")
}

# manifest_path_for <id> [<dir>...] -> echo the script path for a given ID.
# Empty (and rc=1) if not found.
manifest_path_for() {
  local id="$1"
  shift
  local f manifest_id
  while IFS= read -r f; do
    manifest_id=$(manifest_get_field "$f" "II_ID")
    if [[ $manifest_id == "$id" ]]; then
      echo "$f"
      return 0
    fi
  done < <(manifest_list_files "$@")
  return 1
}

# manifest_optional_children_of <id> [<dir>...] -> echo the value of <id>'s
# II_OPTIONAL_GROUP field (space-separated child IDs), or empty if it has no
# such field. The "child" features are add-ons grouped under <id>: they
# get hidden from the top-level Custom checklists and only surface when
# <id> is selected (a sub-menu fires).
manifest_optional_children_of() {
  local id="$1"
  shift
  local path
  path=$(manifest_path_for "$id" "$@")
  [[ -z $path ]] && return 0
  manifest_get_field "$path" "II_OPTIONAL_GROUP"
}

# manifest_is_hidden_child <id> [<dir>...] -> rc=0 if <id> appears in any other
# manifest's II_OPTIONAL_GROUP, rc=1 otherwise.
#
# Used by category filters to hide add-on features from the top-level
# Custom > Options/Software menus — they're meant to be selected via their
# parent's add-on sub-menu, not as standalone picks. Also used by Role-flow
# optional pickers to skip rendering an add-on as a standalone optional
# (the parent's sub-menu fires instead).
manifest_is_hidden_child() {
  local id="$1"
  shift
  local parent_id children child
  while IFS= read -r parent_id; do
    [[ -z $parent_id || $parent_id == "$id" ]] && continue
    children=$(manifest_optional_children_of "$parent_id" "$@")
    for child in $children; do
      [[ "$child" == "$id" ]] && return 0
    done
  done < <(manifest_list_ids "$@")
  return 1
}

# manifest_filter_by_category <category> [<dir>...] -> list IDs matching category.
manifest_filter_by_category() {
  local category="$1"
  shift
  local f id cat
  while IFS= read -r f; do
    cat=$(manifest_get_field "$f" "II_CATEGORY")
    if [[ $cat == "$category" ]]; then
      id=$(manifest_get_field "$f" "II_ID")
      [[ -n $id ]] && echo "$id"
    fi
  done < <(manifest_list_files "$@")
}
