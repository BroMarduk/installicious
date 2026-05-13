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
#   II_RESTRICT_TO_ROLES=""           # space-separated role IDs; empty = visible
#                                     # to every role. When set, the feature is
#                                     # hidden from the Custom-flow checklist
#                                     # under any role not in this list (e.g.
#                                     # skyfield with "weewx" hides under
#                                     # custom / pihole / homeassistant / etc.).
#   II_OPTIONAL_GROUP_MODE=""         # only meaningful on a parent that also
#                                     # declares II_OPTIONAL_GROUP. Values:
#                                     #   "" / "multi"  → checklist (default;
#                                     #                   user picks any subset)
#                                     #   "exclusive"   → radiolist (user picks
#                                     #                   exactly one of the
#                                     #                   listed children)
#                                     # Used by webserver to force a single
#                                     # apache/nginx/lighttpd/caddy choice.
#   II_CONFLICTS_WITH=""              # space-separated IDs that cannot
#                                     # coexist with this one in the same
#                                     # queue. Bidirectional: declaring it on
#                                     # either side is enough (the menu
#                                     # checks both directions when filtering).
#                                     # E.g. weewx-site-ram and
#                                     # webserver-under-construction both
#                                     # manage ${WEEWX_WEB_DIR}/index.html.
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
      _manifest_read_block_into "$f" block
      [[ -z $block ]] && continue
      _manifest_parse_field "$block" "II_ID" id
      [[ -z $id ]] && continue
      _MANIFEST_IDS+=("$id")
      _MANIFEST_PATH[$id]="$f"
    done
  done
  _MANIFEST_LOADED=1
  _MANIFEST_LOADED_FROM="$current_dirs"
}

# _manifest_read_block_into <file> <out-varname>
# Bash-native replacement for the old `block=$(awk ...)` pattern. Sets the
# named variable in the caller's scope to the manifest block content
# (lines between the BEGIN/END sentinels), or to "" if the file lacks
# them. Caches into _MANIFEST_BLOCK on first hit. Avoids both awk and
# the wrapping $() — on Windows Bash where fork+exec is ~100ms each, the
# combined savings are ~6x on hot paths like the registry load.
_manifest_read_block_into() {
  local _file="$1" _out="$2"
  if [[ -n ${_MANIFEST_BLOCK[$_file]:-} ]]; then
    printf -v "$_out" '%s' "${_MANIFEST_BLOCK[$_file]}"
    return 0
  fi
  if [[ ! -f $_file ]]; then
    printf -v "$_out" '%s' ""
    return 0
  fi
  local _line _in=0 _result=""
  while IFS= read -r _line; do
    case $_line in
      "# === II_MANIFEST_BEGIN ==="*) _in=1; continue;;
      "# === II_MANIFEST_END ==="*)   _in=0; continue;;
    esac
    (( _in )) && _result+="$_line"$'\n'
  done < "$_file"
  [[ -n $_result ]] && _MANIFEST_BLOCK[$_file]="$_result"
  printf -v "$_out" '%s' "$_result"
}

# _manifest_parse_field <block> <field> <out-varname>
# Bash-native replacement for the old `value=$(eval "$block"; echo
# "${!field}")` subshell pattern. Walks the block text looking for a line
# starting with "<field>=" and strips wrapping double quotes from the
# value. Manifests are spec'd to be static `KEY="value"` lines so a
# literal text parser is enough — and it's an order of magnitude faster
# than evaluating + reflecting through ${!field} in a subshell.
_manifest_parse_field() {
  local _block="$1" _field="$2" _out="$3"
  local _line _value=""
  while IFS= read -r _line; do
    if [[ $_line == "${_field}="* ]]; then
      _value=${_line#"${_field}"=}
      if [[ ${_value:0:1} == '"' && ${_value: -1} == '"' ]]; then
        _value=${_value:1:${#_value}-2}
      fi
      break
    fi
  done <<<"$_block"
  printf -v "$_out" '%s' "$_value"
}

# manifest_extract <file> -> echo the manifest block content (between sentinels).
# Output is empty if the file lacks the sentinels. Thin wrapper around the
# faster _manifest_read_block_into helper; kept as the public API since
# callers in the test suite use `$(manifest_extract ...)`.
manifest_extract() {
  local _b
  _manifest_read_block_into "$1" _b
  [[ -n $_b ]] && printf '%s' "$_b"
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
  _manifest_read_block_into "$file" block
  if [[ -z $block ]]; then
    _MANIFEST_FIELDS[$cache_key]=""
    return 0
  fi
  local value
  _manifest_parse_field "$block" "$field" value
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
  # Inlined cache+parse (same rationale as manifest_path_for): avoid a
  # fork-per-file from `id=$(manifest_get_field ...)`.
  local f cache_key id block
  while IFS= read -r f; do
    cache_key="$f|II_ID"
    if [[ -n ${_MANIFEST_FIELDS[$cache_key]+set} ]]; then
      id="${_MANIFEST_FIELDS[$cache_key]}"
    else
      _manifest_read_block_into "$f" block
      [[ -z $block ]] && continue
      _manifest_parse_field "$block" "II_ID" id
      _MANIFEST_FIELDS[$cache_key]="$id"
    fi
    [[ -n $id ]] && printf '%s\n' "$id"
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
  # Inlined cache+parse instead of calling `$(manifest_get_field ...)` per
  # file — the inner $() is a subshell fork, and on Windows Bash a
  # fork-per-file in this hot path made test-manifest's post-Test-7 loop
  # take minutes. Reading directly through the printf-v helpers keeps the
  # whole iteration in-shell.
  local f cache_key manifest_id block
  while IFS= read -r f; do
    cache_key="$f|II_ID"
    if [[ -n ${_MANIFEST_FIELDS[$cache_key]+set} ]]; then
      manifest_id="${_MANIFEST_FIELDS[$cache_key]}"
    else
      _manifest_read_block_into "$f" block
      [[ -z $block ]] && continue
      _manifest_parse_field "$block" "II_ID" manifest_id
      _MANIFEST_FIELDS[$cache_key]="$manifest_id"
    fi
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

# manifest_is_visible_for_role <id> <current_role_id> [<dir>...] -> rc=0 if
# the feature/package's II_RESTRICT_TO_ROLES is empty OR contains
# current_role_id; rc=1 if it's restricted to roles that don't include the
# current one.
#
# An empty restriction list (the default for nearly every manifest) means
# "visible everywhere" — the gate is opt-in. A missing manifest is treated
# as visible too, so callers iterating registry IDs never get spurious
# rc=1 from a typo.
#
# Used by scripts/options.sh in the custom_features stage to drop role-
# exclusive features from the per-feature picker. Role flows
# (show_required / pick_optional) trust the role's own tier lists and
# don't consult this helper today.
manifest_is_visible_for_role() {
  local id="$1" current_role="$2"
  shift 2
  local path
  path=$(manifest_path_for "$id" "$@")
  [[ -z $path ]] && return 0
  local restrict
  restrict=$(manifest_get_field "$path" "II_RESTRICT_TO_ROLES")
  [[ -z $restrict ]] && return 0
  local r
  for r in $restrict; do
    [[ "$r" == "$current_role" ]] && return 0
  done
  return 1
}

# manifest_get_conflicts <id> [<dir>...] -> echo space-separated IDs declared
# in this manifest's II_CONFLICTS_WITH. Empty (and rc=0) if the manifest is
# missing or the field is unset. Used by menu filters to drop pickable rows
# that would deadlock with an already-queued feature.
manifest_get_conflicts() {
  local id="$1"
  shift
  local path
  path=$(manifest_path_for "$id" "$@")
  [[ -z $path ]] && return 0
  manifest_get_field "$path" "II_CONFLICTS_WITH"
}

# manifest_is_in_conflict_with <candidate_id> <queue_id>... -> rc=0 if any
# id in <queue_id...> conflicts with <candidate_id>, rc=1 otherwise.
#
# Bidirectional: a conflict declared on EITHER side counts. We check both
# directions so neither side has to know about the other for the gate to
# fire. A missing manifest is treated as not-in-conflict (callers iterate
# registry IDs and we don't want a typo to look like a conflict).
manifest_is_in_conflict_with() {
  local candidate="$1"
  shift
  local cand_conflicts queue_id queue_conflicts c
  cand_conflicts=$(manifest_get_conflicts "$candidate")
  for queue_id in "$@"; do
    [[ -z $queue_id || $queue_id == "$candidate" ]] && continue
    # Direction 1: candidate's manifest lists queue_id
    for c in $cand_conflicts; do
      [[ $c == "$queue_id" ]] && return 0
    done
    # Direction 2: queue_id's manifest lists candidate
    queue_conflicts=$(manifest_get_conflicts "$queue_id")
    for c in $queue_conflicts; do
      [[ $c == "$candidate" ]] && return 0
    done
  done
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
