#!/bin/bash

# lib/menu.sh - Whiptail menu helpers driven by the manifest registry.
#
# Reads II_TITLE and the optional II_DEFAULT_SELECTED ("on"/"off") from each
# manifest in a category, presents a whiptail checklist, and echoes the user's
# selection (whitespace-separated IDs) on stdout.
#
# Usage:
#   source lib/manifest.sh
#   source lib/menu.sh
#   ids=$(menu_select_category option "Installicious Options" "Pick what you want.")

# menu_select_category <category> [<title>] [<description>]
# Returns 0 on user accept (echoes IDs); rc=1 on user cancel (no output);
# rc=2 if no installers exist for the category (no menu shown).
menu_select_category() {
  local category="$1"
  local title="${2:-Installicious}"
  local desc="${3:-Select items from the ${category} category.}"

  local -a items=()
  local id path title_text default
  while IFS= read -r id; do
    path=$(manifest_path_for "$id")
    title_text=$(manifest_get_field "$path" "II_TITLE")
    default=$(manifest_get_field "$path" "II_DEFAULT_SELECTED")
    [[ -z $default ]] && default="off"
    items+=("$id" "$title_text" "$default")
  done < <(manifest_filter_by_category "$category" | sort)

  if [[ ${#items[@]} -eq 0 ]]; then
    return 2
  fi

  whiptail --title "$title" \
    --ok-button "SELECT" \
    --cancel-button "NONE" \
    --checklist "$desc" 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_select_task [<title>] [<description>]
# Single-select whiptail of all task-*.sh manifests under $PATH_TASKS. Echoes
# the selected TASK_ID. rc=1 on cancel; rc=2 if no tasks exist.
menu_select_task() {
  local title="${1:-Installicious — Pick a Task}"
  local desc="${2:-Pick the role for this Pi. Choose Custom to pick installers individually.}"

  local -a items=()
  local id path title_text
  while IFS= read -r id; do
    path=$(task_path_for "$id")
    title_text=$(task_get_field "$path" "TASK_TITLE")
    items+=("$id" "${title_text:-$id}")
  done < <(task_list_ids | sort)

  if [[ ${#items[@]} -eq 0 ]]; then
    return 2
  fi

  whiptail --title "$title" \
    --ok-button "SELECT" \
    --cancel-button "CANCEL" \
    --menu "$desc" 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_show_required <task_title> <required_id> [<required_id> ...]
# Informational msgbox listing the required installers for a task, with each
# installer's manifest title. No user input beyond OK; rc=0.
menu_show_required() {
  local task_title="$1"
  shift
  local message="$task_title will install:"
  local id installer_path installer_title
  for id in "$@"; do
    installer_path=$(manifest_path_for "$id" 2>/dev/null)
    if [[ -n $installer_path ]]; then
      installer_title=$(manifest_get_field "$installer_path" "II_TITLE")
      message+="\n  - $id  ($installer_title)"
    else
      message+="\n  - $id  (no installer manifest found)"
    fi
  done
  message+="\n\nThese are required and will run automatically. Optional add-ons come next."
  whiptail --title "$task_title — Required Installers" --msgbox "$message" 20 80
}

# menu_pick_optionals <task_title> <optional_id> [<optional_id> ...]
# Multi-select whiptail of optional installers, all default-off. Echoes the
# selected IDs (space-separated, possibly quoted by whiptail). rc=1 on cancel.
# Skips the menu (rc=0, no output) if the optional list is empty.
menu_pick_optionals() {
  local task_title="$1"
  shift
  if [[ $# -eq 0 ]]; then
    return 0
  fi

  local -a items=()
  local id path installer_title
  for id in "$@"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    if [[ -n $path ]]; then
      installer_title=$(manifest_get_field "$path" "II_TITLE")
    else
      installer_title=""
    fi
    items+=("$id" "${installer_title:-$id}" "off")
  done

  whiptail --title "$task_title — Optional Add-ons" \
    --ok-button "SELECT" \
    --cancel-button "NONE" \
    --checklist "Optional add-ons (default off; pick any you want)." 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_confirm <title> <message>
# Yes/no whiptail. rc=0 if user confirms.
menu_confirm() {
  local title="$1"
  local message="$2"
  whiptail --title "$title" \
    --yes-button "RUN" \
    --no-button "CANCEL" \
    --yesno "$message" 20 80
}
