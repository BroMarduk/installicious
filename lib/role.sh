#!/bin/bash

# lib/role.sh - Role manifest extraction & registry.
#
# Installicious has three tiers of definition:
#
#   ROLE     — top-level "what is this Pi for" pick (Custom, Pi-Hole, WeeWx,
#              Home Assistant, Media Server, …). The user picks exactly one
#              role at the start of an install.
#   FEATURE  — a coherent piece of functionality (motd, weewx, pihole-core,
#              raspi-config tweaks, …). A role pulls in some required
#              features (shown but not toggleable) and may default-select or
#              offer additional optional features. Lives as feature-*.sh
#              under $PATH_FEATURES.
#   PACKAGE  — a raw apt package installable independently or required by a
#              feature. Lives as package-*.sh under $PATH_PACKAGES.
#
# Each role lives in $PATH_ROLES/role-<id>.sh with a fenced manifest block:
#
#   # === II_ROLE_BEGIN ===
#   ROLE_ID="pihole"
#   ROLE_TITLE="Pi-Hole — DNS Sinkhole"
#   ROLE_DESCRIPTION="Network-wide ad blocking via DNS server."
#   ROLE_FEATURES_REQUIRED="pkupd pihole-core"     # mandatory; not toggleable
#   ROLE_FEATURES_DEFAULT="locale bash"            # pre-checked; user can deselect
#   ROLE_FEATURES_OPTIONAL="rconf motd ssh"        # unchecked; user can add
#   ROLE_CONFIG="config/role-pihole.config"
#   ROLE_EDITABLE_CONFIG="PIHOLE_WEB_PASSWORD PIHOLE_HOSTNAME"
#   # === II_ROLE_END ===
#
# Three feature tiers, in order of how the menu surfaces them:
#   REQUIRED  — shown via menu_show_required (info-only confirmation).
#               Always installed.
#   DEFAULT   — pre-checked items in the optional checklist. User can
#               uncheck any of them to skip that feature.
#   OPTIONAL  — unchecked items in the same checklist. User can check
#               any to add them.
#
# When ALL three are empty (the stub roles), the dispatcher falls
# through to the per-feature picker (Custom flow) so the role still
# does something useful.
#
# Per-feature II_DEFAULT_SELECTED in the manifest only matters in the
# Custom flow — once a role places a feature into one of its three
# tiers explicitly, the role's choice wins.
#
# Helpers parallel lib/manifest.sh.

_role_default_dir() {
  echo "${PATH_ROLES:-roles}"
}

# role_extract <file> -> echo the manifest block content (between sentinels).
# Thin wrapper around _role_read_block_into; kept for test compatibility.
role_extract() {
  local _b
  _role_read_block_into "$1" _b
  [[ -n $_b ]] && printf '%s' "$_b"
}

# _role_read_block_into <file> <out-varname>
# Bash-native replacement for the old `awk` extraction. Sets the named
# variable in the caller's scope to the role block content. Mirrors
# _manifest_read_block_into; avoids both awk and $() so first-time role
# reads aren't dominated by fork/exec on Windows Bash.
_role_read_block_into() {
  local _file="$1" _out="$2"
  if [[ ! -f $_file ]]; then
    printf -v "$_out" '%s' ""
    return 0
  fi
  local _line _in=0 _result=""
  while IFS= read -r _line; do
    case $_line in
      "# === II_ROLE_BEGIN ==="*) _in=1; continue;;
      "# === II_ROLE_END ==="*)   _in=0; continue;;
    esac
    (( _in )) && _result+="$_line"$'\n'
  done < "$_file"
  printf -v "$_out" '%s' "$_result"
}

# _role_parse_field <block> <field> <out-varname>
# Same KEY="value" text parser as the manifest side. Roles only declare
# a tiny set of well-typed string fields, so eval is overkill.
_role_parse_field() {
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

# role_get_field <file> <field> -> echo single field value.
role_get_field() {
  local file="$1"
  local field="$2"
  local block value
  _role_read_block_into "$file" block
  [[ -z $block ]] && return 0
  _role_parse_field "$block" "$field" value
  printf '%s\n' "$value"
}

# role_list_files [<dir>] -> list role-script paths.
role_list_files() {
  local dir="${1:-$(_role_default_dir)}"
  [[ -d $dir ]] || return 0
  local f
  for f in "$dir"/role-*.sh; do
    [[ -f $f ]] && echo "$f"
  done
}

# role_list_ids [<dir>] -> list IDs of roles that have a valid manifest.
# Inlined to skip the `id=$(role_get_field ...)` subshell per file (same
# rationale as manifest_list_ids).
role_list_ids() {
  local dir="${1:-$(_role_default_dir)}"
  local f block id
  while IFS= read -r f; do
    _role_read_block_into "$f" block
    [[ -z $block ]] && continue
    _role_parse_field "$block" "ROLE_ID" id
    [[ -n $id ]] && printf '%s\n' "$id"
  done < <(role_list_files "$dir")
}

# role_path_for <id> [<dir>] -> echo role-script path for an ID. rc=1 if not found.
role_path_for() {
  local id="$1"
  local dir="${2:-$(_role_default_dir)}"
  local f block manifest_id
  while IFS= read -r f; do
    _role_read_block_into "$f" block
    [[ -z $block ]] && continue
    _role_parse_field "$block" "ROLE_ID" manifest_id
    if [[ $manifest_id == "$id" ]]; then
      echo "$f"
      return 0
    fi
  done < <(role_list_files "$dir")
  return 1
}
