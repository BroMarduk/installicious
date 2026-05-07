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
#   II_CATEGORY="feature"             # feature (in features/) | package (in packages/)
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

# ---------------------------------------------------------------------------
# Registry cache
# ---------------------------------------------------------------------------
#
# Production manifests don't change at runtime, so re-scanning the directory
# tree (and re-awking each file) on every helper call is wasted work. The
# scheduler + menu helpers can fan out to hundreds of awks per category
# render — manifest_is_hidden_child alone is O(n²) — and on a Pi that adds
# real human-visible latency between menus.
#
# Caches:
#   _MANIFEST_PATH[id]          -> file path
#   _MANIFEST_BLOCK[file]       -> manifest block content (skips awk)
#   _MANIFEST_FIELDS[file|field]-> single field value (skips eval/subshell)
#   _MANIFEST_FILES             -> ordered list of files in default dirs
#   _MANIFEST_IDS               -> ordered list of IDs in default dirs
#   _MANIFEST_LOADED_FROM       -> "$PATH_FEATURES|$PATH_PACKAGES" snapshot
#
# Cache scope: only the no-arg "scan default dirs" path uses the populated
# registry. Helpers called with explicit dir args bypass the registry —
# tests that build synthetic manifests in a tempdir and pass it in stay
# unaffected. The per-file _MANIFEST_BLOCK / _MANIFEST_FIELDS caches DO
# accelerate explicit-dir paths once a file has been parsed once.
#
# Auto-invalidation: if $PATH_FEATURES / $PATH_PACKAGES change between
# calls, _MANIFEST_LOADED_FROM mismatches and the registry reloads.
#
# Tests that mutate the file set in-place (e.g., scheduler tests adding
# new feature-*.sh files via mk_installer) must call
# manifest_registry_reload after the mutation.

declare -gA _MANIFEST_PATH
declare -gA _MANIFEST_BLOCK
declare -gA _MANIFEST_FIELDS
declare -ga _MANIFEST_FILES
declare -ga _MANIFEST_IDS
_MANIFEST_LOADED=0
_MANIFEST_LOADED_FROM=""

# manifest_registry_reload — drop all caches. Call from tests that add or
# rewrite manifest files at runtime.
manifest_registry_reload() {
  _MANIFEST_PATH=()
  _MANIFEST_BLOCK=()
  _MANIFEST_FIELDS=()
  _MANIFEST_FILES=()
  _MANIFEST_IDS=()
  _MANIFEST_LOADED=0
  _MANIFEST_LOADED_FROM=""
}

_manifest_registry_load() {
  local current_dirs
  current_dirs="${PATH_FEATURES:-features}|${PATH_PACKAGES:-packages}"
  if [[ $_MANIFEST_LOADED -eq 1 && $_MANIFEST_LOADED_FROM == "$current_dirs" ]]; then
    return 0
  fi

  # Env vars changed (or never loaded) — clear and rebuild.
  _MANIFEST_PATH=()
  _MANIFEST_FILES=()
  _MANIFEST_IDS=()

  local -a dirs
  # shellcheck disable=SC2207
  dirs=( $(_manifest_default_dirs) )
  local d f block id
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    for f in "$d"/feature-*.sh "$d"/package-*.sh; do
      [[ -f $f ]] || continue
      _MANIFEST_FILES+=("$f")
      block=$(awk '
        /^# === II_MANIFEST_BEGIN ===/ {flag=1; next}
        /^# === II_MANIFEST_END ===/   {flag=0}
        flag                            {print}
      ' "$f")
      [[ -z $block ]] && continue
      _MANIFEST_BLOCK[$f]="$block"
      id=$(
        # shellcheck disable=SC2086
        eval "$block"
        echo "$II_ID"
      )
      [[ -z $id ]] && continue
      _MANIFEST_IDS+=("$id")
      _MANIFEST_PATH[$id]="$f"
    done
  done
  _MANIFEST_LOADED=1
  _MANIFEST_LOADED_FROM="$current_dirs"
}

# manifest_extract <file> -> echo the manifest block content (between sentinels).
# Output is empty if the file lacks the sentinels.
manifest_extract() {
  local file="$1"
  if [[ -n ${_MANIFEST_BLOCK[$file]:-} ]]; then
    printf '%s\n' "${_MANIFEST_BLOCK[$file]}"
    return 0
  fi
  [[ -f $file ]] || return 0
  local block
  block=$(awk '
    /^# === II_MANIFEST_BEGIN ===/ {flag=1; next}
    /^# === II_MANIFEST_END ===/   {flag=0}
    flag                            {print}
  ' "$file")
  if [[ -n $block ]]; then
    _MANIFEST_BLOCK[$file]="$block"
    printf '%s\n' "$block"
  fi
}

# manifest_get_field <file> <field> -> echo the value of a single manifest field.
# Empty if file or field is missing. Caches the field value so repeated
# lookups skip the eval/subshell.
manifest_get_field() {
  local file="$1"
  local field="$2"
  local cache_key="$file|$field"
  if [[ -n ${_MANIFEST_FIELDS[$cache_key]+set} ]]; then
    printf '%s\n' "${_MANIFEST_FIELDS[$cache_key]}"
    return 0
  fi
  local block
  if [[ -n ${_MANIFEST_BLOCK[$file]:-} ]]; then
    block="${_MANIFEST_BLOCK[$file]}"
  else
    block=$(manifest_extract "$file")
    [[ -z $block ]] && return 0
  fi
  local value
  value=$(
    # shellcheck disable=SC2086
    eval "$block"
    echo "${!field}"
  )
  _MANIFEST_FIELDS[$cache_key]="$value"
  printf '%s\n' "$value"
}

# manifest_list_files [<dir>...] -> list manifest-bearing paths (one per line).
# With no args, returns the cached default-dir registry (loads on first call).
manifest_list_files() {
  if [[ $# -eq 0 ]]; then
    _manifest_registry_load
    [[ ${#_MANIFEST_FILES[@]} -gt 0 ]] && printf '%s\n' "${_MANIFEST_FILES[@]}"
    return 0
  fi
  local d f
  for d in "$@"; do
    [[ -d $d ]] || continue
    for f in "$d"/feature-*.sh "$d"/package-*.sh; do
      [[ -f $f ]] && echo "$f"
    done
  done
}

# manifest_list_ids [<dir>...] -> list IDs that have a valid manifest.
manifest_list_ids() {
  if [[ $# -eq 0 ]]; then
    _manifest_registry_load
    [[ ${#_MANIFEST_IDS[@]} -gt 0 ]] && printf '%s\n' "${_MANIFEST_IDS[@]}"
    return 0
  fi
  local f id
  while IFS= read -r f; do
    id=$(manifest_get_field "$f" "II_ID")
    [[ -n $id ]] && echo "$id"
  done < <(manifest_list_files "$@")
}

# manifest_path_for <id> [<dir>...] -> echo the script path for a given ID.
# Empty (and rc=1) if not found. Default-dirs lookups hit the cached
# id→path map; explicit-dir lookups still scan.
manifest_path_for() {
  local id="$1"
  shift
  if [[ $# -eq 0 ]]; then
    _manifest_registry_load
    if [[ -n ${_MANIFEST_PATH[$id]:-} ]]; then
      echo "${_MANIFEST_PATH[$id]}"
      return 0
    fi
    return 1
  fi
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

  # Fast path: with no explicit dirs and a loaded registry, walk
  # _MANIFEST_IDS / _MANIFEST_PATH directly so we skip the inner
  # $(manifest_optional_children_of ...) subshell per parent. This
  # function runs once per ID per category render, so the savings
  # compound — was the dominant cost on a Pi.
  if [[ $# -eq 0 ]]; then
    _manifest_registry_load
    local parent_id ppath children child fkey
    for parent_id in "${_MANIFEST_IDS[@]}"; do
      [[ -z $parent_id || $parent_id == "$id" ]] && continue
      ppath="${_MANIFEST_PATH[$parent_id]:-}"
      [[ -z $ppath ]] && continue
      fkey="$ppath|II_OPTIONAL_GROUP"
      if [[ -n ${_MANIFEST_FIELDS[$fkey]+set} ]]; then
        children="${_MANIFEST_FIELDS[$fkey]}"
      else
        children=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
      fi
      for child in $children; do
        [[ "$child" == "$id" ]] && return 0
      done
    done
    return 1
  fi

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
