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

# ---------------------------------------------------------------------------
# Configuration editor
# ---------------------------------------------------------------------------

# _menu_read_var_chain <var> <config_file...>
# Sources each config file in a subshell (in order) plus any prior
# state/menu-config.sh, then echoes the value of <var>. The subshell isolates
# the sources from the caller's env. Empty if var is unset after all sources.
_menu_read_var_chain() {
  local var="$1"
  shift
  (
    local f
    for f in "$@"; do
      [[ -f $f ]] && source "$f" 2>/dev/null
    done
    [[ -f "${PATH_STATE:-state}/menu-config.sh" ]] \
      && source "${PATH_STATE:-state}/menu-config.sh" 2>/dev/null
    echo "${!var}"
  )
}

# menu_edit_config <task_id> <installer_id...>
# Discovers editable keys from the chosen task's TASK_EDITABLE_CONFIG and each
# selected installer's II_EDITABLE_CONFIG manifest field. Reads default values
# from the corresponding .config files (chained: installicious.config first,
# then task config, then per-installer config, then any prior menu-config.sh).
# Loops a whiptail menu+inputbox until the user picks DONE. Persists the final
# values to $PATH_STATE/menu-config.sh. No-op if there are zero editable keys.
#
# Pass task_id="" when running the Custom flow (no task config), and just the
# selected installer IDs.
menu_edit_config() {
  local task_id="$1"
  shift
  local -a installer_ids=("$@")

  # ---- discover editable keys + their owning labels ----
  declare -A key_label key_seen
  local -a config_files=("config/installicious.config")

  if [[ -n $task_id && $task_id != "custom" ]]; then
    local task_path
    task_path=$(task_path_for "$task_id" 2>/dev/null)
    if [[ -n $task_path ]]; then
      local task_config_file task_editable
      task_config_file=$(task_get_field "$task_path" "TASK_CONFIG")
      task_editable=$(task_get_field "$task_path" "TASK_EDITABLE_CONFIG")
      [[ -n $task_config_file && -f $task_config_file ]] && config_files+=("$task_config_file")
      local key
      for key in $task_editable; do
        [[ -z $key ]] && continue
        key_seen[$key]=1
        key_label[$key]="task:$task_id"
      done
    fi
  fi

  local id path config_file editable
  for id in "${installer_ids[@]}"; do
    [[ -z $id ]] && continue
    path=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $path ]] && continue
    config_file="${PATH_CONFIG:-config}/$id.config"
    [[ -f $config_file ]] && config_files+=("$config_file")
    editable=$(manifest_get_field "$path" "II_EDITABLE_CONFIG")
    for key in $editable; do
      [[ -z $key ]] && continue
      [[ -n ${key_seen[$key]:-} ]] && continue
      key_seen[$key]=1
      key_label[$key]="$id"
    done
  done

  if [[ ${#key_seen[@]} -eq 0 ]]; then
    return 0  # nothing to edit
  fi

  # ---- read current values via the chain ----
  declare -A current
  for key in "${!key_seen[@]}"; do
    current[$key]=$(_menu_read_var_chain "$key" "${config_files[@]}")
  done

  # ---- edit loop ----
  local choice new_val rc
  while true; do
    local -a items=()
    local -a sorted_keys
    mapfile -t sorted_keys < <(printf '%s\n' "${!current[@]}" | sort)
    for key in "${sorted_keys[@]}"; do
      items+=("$key" "[${key_label[$key]}] ${current[$key]}")
    done

    choice=$(whiptail --title "Edit Configuration" \
      --ok-button "EDIT" --cancel-button "DONE" \
      --menu "Pick a value to edit, or DONE to continue:" 20 80 12 \
      "${items[@]}" \
      3>&1 1>&2 2>&3)
    rc=$?
    [[ $rc -ne 0 ]] && break

    new_val=$(whiptail --title "$choice [${key_label[$choice]}]" \
      --inputbox "Enter new value for $choice:" \
      10 70 "${current[$choice]}" \
      3>&1 1>&2 2>&3)
    rc=$?
    [[ $rc -ne 0 ]] && continue
    current[$choice]="$new_val"
  done

  # ---- persist to menu-config.sh ----
  local override_file="${PATH_STATE:-state}/menu-config.sh"
  local override_dir
  override_dir=$(dirname "$override_file")
  if [[ ! -d $override_dir ]]; then
    mkdir -p "$override_dir" 2>/dev/null || sudo mkdir -p "$override_dir" || return 1
  fi

  {
    echo "# Generated by installicious menu_edit_config — runtime overrides for the current run."
    echo "# Sourced by each installer after its baseline .config files; values here win."
    for key in "${!current[@]}"; do
      printf '%s=%q\n' "$key" "${current[$key]}"
    done
  } > "$override_file" 2>/dev/null || {
    {
      echo "# Generated by installicious menu_edit_config — runtime overrides for the current run."
      echo "# Sourced by each installer after its baseline .config files; values here win."
      for key in "${!current[@]}"; do
        printf '%s=%q\n' "$key" "${current[$key]}"
      done
    } | sudo tee "$override_file" >/dev/null
  }
}
