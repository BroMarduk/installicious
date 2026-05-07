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
role_extract() {
  local file="$1"
  [[ -f $file ]] || return 0
  awk '
    /^# === II_ROLE_BEGIN ===/ {flag=1; next}
    /^# === II_ROLE_END ===/   {flag=0}
    flag                        {print}
  ' "$file"
}

# role_get_field <file> <field> -> echo single field value.
# Sourced in a subshell to avoid polluting the caller's environment.
role_get_field() {
  local file="$1"
  local field="$2"
  local block
  block=$(role_extract "$file")
  [[ -z $block ]] && return 0
  (
    # shellcheck disable=SC2086
    eval "$block"
    echo "${!field}"
  )
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
role_list_ids() {
  local dir="${1:-$(_role_default_dir)}"
  local f id
  while IFS= read -r f; do
    id=$(role_get_field "$f" "ROLE_ID")
    [[ -n $id ]] && echo "$id"
  done < <(role_list_files "$dir")
}

# role_path_for <id> [<dir>] -> echo role-script path for an ID. rc=1 if not found.
role_path_for() {
  local id="$1"
  local dir="${2:-$(_role_default_dir)}"
  local f manifest_id
  while IFS= read -r f; do
    manifest_id=$(role_get_field "$f" "ROLE_ID")
    if [[ $manifest_id == "$id" ]]; then
      echo "$f"
      return 0
    fi
  done < <(role_list_files "$dir")
  return 1
}
