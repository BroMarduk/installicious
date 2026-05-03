#!/bin/bash

# lib/menu.sh - Whiptail menu helpers driven by the manifest registry.
#
# Reads II_TITLE and the optional II_DEFAULT_SELECTED ("on"/"off") from each
# manifest in a category, presents a whiptail checklist, and echoes the user's
# selection (whitespace-separated IDs) on stdout.
#
# Return-code convention used across all helpers (so scripts/options.sh can
# drive a stage state machine):
#   0   forward     — user pressed the OK / NEXT / RUN button
#   1   back        — user pressed the BACK button (or CANCEL on first stage)
#   2   no-data     — nothing to show (caller should auto-advance silently)
#   255 abort       — user pressed ESC; abort the whole flow
#
# Usage:
#   source lib/manifest.sh
#   source lib/menu.sh
#   ids=$(menu_select_category option "Installicious Options" "Pick what you want.")

# menu_select_category <category> [<title>] [<description>]
# Multi-select checklist for the given manifest category. Echoes the selected
# IDs on stdout when the user picks NEXT.
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
    --ok-button "NEXT" \
    --cancel-button "BACK" \
    --checklist "$desc" 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_select_task [<title>] [<description>]
# First-stage single-select task picker. CANCEL means exit (no previous stage
# to go back to); ESC also exits.
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
    --cancel-button "EXIT" \
    --menu "$desc" 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_show_required <task_title> <required_id> [<required_id> ...]
# Informational confirmation listing the required installers for a task.
# OK forwards (rc=0), BACK rewinds (rc=1), ESC aborts (rc=255).
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
  whiptail --title "$task_title — Required Installers" \
    --yes-button "OK" \
    --no-button "BACK" \
    --yesno "$message" 20 80
}

# menu_pick_optionals <task_title> <optional_id> [<optional_id> ...]
# Multi-select checklist of optional installers, all default-off. Echoes the
# selected IDs (space-separated, possibly quoted by whiptail).
menu_pick_optionals() {
  local task_title="$1"
  shift
  if [[ $# -eq 0 ]]; then
    return 2
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
    --ok-button "NEXT" \
    --cancel-button "BACK" \
    --checklist "Optional add-ons (default off; pick any you want)." 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_confirm <title> <message>
# Final yes/no. RUN forwards, BACK rewinds.
menu_confirm() {
  local title="$1"
  local message="$2"
  whiptail --title "$title" \
    --yes-button "RUN" \
    --no-button "BACK" \
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
# then per-installer configs, then task config, then any prior menu-config.sh).
# Loops a whiptail menu+inputbox until the user picks DONE or BACK. Persists
# the final values to $PATH_STATE/menu-config.sh on DONE.
#
# Return codes (matches the lib/menu.sh contract):
#   0   forward — user pressed DONE; overrides persisted
#   1   back    — user pressed BACK or selected the "<-- Back" entry; overrides
#                 are NOT persisted (caller can re-enter the previous stage)
#   2   no-data — no editable keys advertised; nothing to show, caller should
#                 auto-advance
#   255 abort   — user pressed ESC
#
# Pass task_id="" or "custom" when running the Custom flow (no task config).
menu_edit_config() {
  local task_id="$1"
  shift
  local -a installer_ids=("$@")

  # ---- discover editable keys + their owning labels ----
  #
  # Source order in config_files matters: later entries win in
  # _menu_read_var_chain. To honor "task config overrides installer config",
  # we append per-installer configs first, then the task config last (so
  # task values shadow any colliding installer defaults). The user's
  # menu-config.sh is layered on top of all of these by the chain helper.
  declare -A key_label key_seen
  local -a config_files=("config/installicious.config")
  local key
  local task_config_file=""
  local task_editable=""

  if [[ -n $task_id && $task_id != "custom" ]]; then
    local task_path
    task_path=$(task_path_for "$task_id" 2>/dev/null)
    if [[ -n $task_path ]]; then
      task_config_file=$(task_get_field "$task_path" "TASK_CONFIG")
      task_editable=$(task_get_field "$task_path" "TASK_EDITABLE_CONFIG")
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

  # Task config sources LAST so its values win over any colliding installer
  # config defaults (per the "task overrides installer" rule).
  [[ -n $task_config_file && -f $task_config_file ]] && config_files+=("$task_config_file")

  if [[ ${#key_seen[@]} -eq 0 ]]; then
    return 2  # nothing to edit; caller auto-advances
  fi

  # ---- read current values via the chain ----
  declare -A current
  for key in "${!key_seen[@]}"; do
    current[$key]=$(_menu_read_var_chain "$key" "${config_files[@]}")
  done

  # ---- edit loop ----
  # Buttons: OK="EDIT" → edit highlighted row; CANCEL="DONE" → forward.
  # "<-- Back" appears as the first menu entry; selecting it exits with rc=1.
  # ESC → rc=255 (abort).
  local choice new_val rc final_rc=0
  while true; do
    local -a items=()
    items+=("__BACK__" "<-- Back to previous screen")
    local -a sorted_keys
    mapfile -t sorted_keys < <(printf '%s\n' "${!current[@]}" | sort)
    for key in "${sorted_keys[@]}"; do
      items+=("$key" "[${key_label[$key]}] ${current[$key]}")
    done

    choice=$(whiptail --title "Edit Configuration" \
      --ok-button "EDIT" --cancel-button "DONE" \
      --menu "Pick a value to edit, DONE to continue, or <-- Back to rewind." 20 80 12 \
      "${items[@]}" \
      3>&1 1>&2 2>&3)
    rc=$?
    if [[ $rc -eq 255 ]]; then
      return 255  # ESC
    fi
    if [[ $rc -ne 0 ]]; then
      final_rc=0  # DONE pressed → forward
      break
    fi
    if [[ $choice == "__BACK__" ]]; then
      return 1
    fi

    new_val=$(whiptail --title "$choice [${key_label[$choice]}]" \
      --inputbox "Enter new value for $choice:" \
      10 70 "${current[$choice]}" \
      3>&1 1>&2 2>&3)
    rc=$?
    [[ $rc -eq 255 ]] && return 255
    [[ $rc -ne 0 ]] && continue  # cancel on input box → discard edit, back to list
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
  return 0
}
