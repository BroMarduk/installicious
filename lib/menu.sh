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
#   255 abort/ESC   — user pressed ESC. options.sh maps this to BACK on
#                     every stage EXCEPT the first (the splash whiptail in
#                     installicious.sh and menu_select_task here), where
#                     ESC means exit the installer.
#
# Usage:
#   source lib/manifest.sh
#   source lib/menu.sh
#   ids=$(menu_select_category option "Installicious Options" "Pick what you want.")

# menu_select_category <category> [<title>] [<description>] [<previously_selected>]
# Multi-select checklist for the given manifest category. Echoes the selected
# IDs on stdout when the user picks NEXT.
#
# If <previously_selected> (space-separated IDs, no quotes) is provided, those
# IDs are pre-checked and any others are unchecked — overriding the manifest's
# II_DEFAULT_SELECTED. This is how options.sh preserves the user's prior
# selections when they navigate BACK and then forward again.
menu_select_category() {
  local category="$1"
  local title="${2:-Installicious}"
  local desc="${3:-Select items from the ${category} category.}"
  local previously="${4:-}"

  local use_previously=0
  declare -A on_set=()
  if [[ -n $previously ]]; then
    use_previously=1
    local sel
    for sel in $previously; do
      [[ -n $sel ]] && on_set[$sel]=1
    done
  fi

  local -a items=()
  local id path title_text default
  while IFS= read -r id; do
    # Skip add-on installers — they belong under their parent's sub-menu
    # (see manifest_is_hidden_child / II_OPTIONAL_GROUP).
    manifest_is_hidden_child "$id" && continue
    path=$(manifest_path_for "$id")
    title_text=$(manifest_get_field "$path" "II_TITLE")
    if [[ $use_previously -eq 1 ]]; then
      [[ -n ${on_set[$id]:-} ]] && default="on" || default="off"
    else
      default=$(manifest_get_field "$path" "II_DEFAULT_SELECTED")
      [[ -z $default ]] && default="off"
    fi
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

# menu_select_task [<title>] [<description>] [<default_item>]
# First-stage single-select task picker. CANCEL means exit (no previous stage
# to go back to); ESC also exits. If <default_item> is provided and matches a
# task ID, that row is highlighted by default — useful for preserving the
# user's prior pick when they navigate BACK to this screen.
menu_select_task() {
  local title="${1:-Installicious — Pick a Task}"
  local desc="${2:-Pick the role for this Pi. Choose Custom to pick installers individually.}"
  local default_item="${3:-}"

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

  local -a wt_args=(--title "$title" --ok-button "SELECT" --cancel-button "EXIT")
  [[ -n $default_item ]] && wt_args+=(--default-item "$default_item")
  wt_args+=(--menu "$desc" 20 80 12 "${items[@]}")
  whiptail "${wt_args[@]}" 3>&1 1>&2 2>&3
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

# menu_pick_optionals <task_title> [--previously <selected>] <optional_id> [<optional_id> ...]
# Multi-select checklist of optional installers, all default-off. Echoes the
# selected IDs (space-separated, possibly quoted by whiptail).
#
# Pass --previously "<space-separated-ids>" before the optional ID list to
# pre-check those rows (overriding the default-off baseline). Used by
# options.sh to preserve the user's prior picks when they navigate BACK and
# then forward again.
menu_pick_optionals() {
  local task_title="$1"
  shift
  local previously=""
  if [[ "${1:-}" == "--previously" ]]; then
    previously="$2"
    shift 2
  fi
  if [[ $# -eq 0 ]]; then
    return 2
  fi

  local use_previously=0
  declare -A on_set=()
  if [[ -n $previously ]]; then
    use_previously=1
    local sel
    for sel in $previously; do
      [[ -n $sel ]] && on_set[$sel]=1
    done
  fi

  local -a items=()
  local id path installer_title default
  for id in "$@"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    if [[ -n $path ]]; then
      installer_title=$(manifest_get_field "$path" "II_TITLE")
    else
      installer_title=""
    fi
    if [[ $use_previously -eq 1 ]]; then
      [[ -n ${on_set[$id]:-} ]] && default="on" || default="off"
    else
      default="off"
    fi
    items+=("$id" "${installer_title:-$id}" "$default")
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

# menu_key_applicable <key>
# Returns 0 if the editable key applies on this system, 1 if not.
#
# Convention (used by both menu_edit_config and installer bodies):
#   _applies_<KEY>()  - optional. Returns 0 if applicable, 1 if not. Used for
#                       free-form keys with hardware/OS gating (e.g. RCONF_FAN_GPIO
#                       which is text-input but only applicable on Pi 4).
#   _choices_<KEY>()  - optional. Echoes "value<TAB>label" lines for an
#                       enumerated key, or empty if not applicable. Defining
#                       this makes the key render as a whiptail --menu instead
#                       of an inputbox; empty output also gates applicability.
#
# When neither helper is defined, the key is always applicable (free-form).
# Both menu_edit_config (filtering display) and the installer body (skipping
# the apply call) share this so config values for an inapplicable key get
# silently ignored, per the user's stated rule.
menu_key_applicable() {
  local key="$1"
  if declare -F "_applies_$key" >/dev/null; then
    "_applies_$key" && return 0 || return 1
  fi
  if declare -F "_choices_$key" >/dev/null; then
    local out
    out=$("_choices_$key")
    [[ -n $out ]] && return 0 || return 1
  fi
  return 0
}

# _menu_source_choices_for <id>
# Sources installers/install-<id>.choices.sh if present so its _choices_*/
# _applies_* functions become available. Side-effect-free: choices files
# define functions only.
_menu_source_choices_for() {
  local id="$1"
  local path="${PATH_INSTALLERS:-installers}/install-${id}.choices.sh"
  if [[ -f $path ]]; then
    # shellcheck disable=SC1090
    source "$path"
  fi
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

  # ---- source per-installer choices files for any installer contributing keys ----
  # Each <id> contributing keys gets its install-<id>.choices.sh sourced once
  # so menu_key_applicable + the editor's whiptail-menu rendering can see
  # _choices_<KEY> / _applies_<KEY> functions.
  declare -A sourced_choices
  local owner_id
  for key in "${!key_seen[@]}"; do
    owner_id="${key_label[$key]}"
    owner_id="${owner_id#task:}"  # strip task: prefix if present
    [[ -z $owner_id || $owner_id == "task" ]] && continue
    [[ -n ${sourced_choices[$owner_id]:-} ]] && continue
    sourced_choices[$owner_id]=1
    _menu_source_choices_for "$owner_id"
  done

  # ---- filter keys by applicability ----
  # A key is hidden from the menu (and its config value will also be ignored
  # by the installer body) if its _applies_/_choices_ helper says it doesn't
  # apply on this system (Pi model, OS version, Lite vs Full).
  for key in "${!key_seen[@]}"; do
    if ! menu_key_applicable "$key"; then
      unset 'key_seen[$key]'
      unset 'key_label[$key]'
    fi
  done
  if [[ ${#key_seen[@]} -eq 0 ]]; then
    return 2  # nothing applies on this system
  fi

  # ---- read current values via the chain ----
  declare -A current
  for key in "${!key_seen[@]}"; do
    current[$key]=$(_menu_read_var_chain "$key" "${config_files[@]}")
  done

  # ---- edit loop ----
  # Buttons: OK="EDIT" → edit highlighted row; CANCEL="DONE" → forward.
  # "<-- Back" appears as the first menu entry; selecting it sets result_rc=1
  # and breaks. Both DONE and BACK fall through to the persist block — that
  # way an in-progress edit is remembered if the user goes back and returns.
  # ESC bypasses persistence and returns 255.
  local choice new_val rc result_rc=0
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
    # ESC and BACK both rewind to the previous stage with the user's edits
    # persisted. Only DONE (the cancel-button label, rc!=0 with no choice)
    # forwards; only the explicit "<-- Back" entry (rc=0 with that value)
    # rewinds with persistence. ESC behaves like BACK rather than abort,
    # per the back-button-everywhere policy (splash + task picker excepted).
    if [[ $rc -eq 255 ]]; then
      result_rc=1  # ESC → treat like BACK (persist + rewind)
      break
    fi
    if [[ $rc -ne 0 ]]; then
      result_rc=0  # DONE → forward
      break
    fi
    if [[ $choice == "__BACK__" ]]; then
      result_rc=1  # BACK entry → rewind, with persist below
      break
    fi

    # Enumerated keys (those with a _choices_<KEY> function) render as a
    # whiptail --menu instead of a free-form input box. The function returns
    # tab-separated "value<TAB>label" lines; we feed both into whiptail and
    # capture the chosen value on stdout. Free-form keys keep the inputbox.
    if declare -F "_choices_$choice" >/dev/null; then
      local -a choice_lines=()
      mapfile -t choice_lines < <("_choices_$choice")
      local -a choice_items=()
      local cline cval clabel
      for cline in "${choice_lines[@]}"; do
        [[ -z $cline ]] && continue
        if [[ $cline == *$'\t'* ]]; then
          cval="${cline%%$'\t'*}"
          clabel="${cline#*$'\t'}"
        else
          cval="$cline"
          clabel="$cline"
        fi
        choice_items+=("$cval" "$clabel")
      done
      new_val=$(whiptail --title "$choice [${key_label[$choice]}]" \
        --default-item "${current[$choice]}" \
        --menu "Select a value for $choice:" 20 80 12 \
        "${choice_items[@]}" \
        3>&1 1>&2 2>&3)
    else
      new_val=$(whiptail --title "$choice [${key_label[$choice]}]" \
        --inputbox "Enter new value for $choice:" \
        10 70 "${current[$choice]}" \
        3>&1 1>&2 2>&3)
    fi
    rc=$?
    # cancel OR ESC on a value-input screen → discard the in-progress edit,
    # return to the editor list (treat ESC like Cancel here, not abort).
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
  return $result_rc
}
