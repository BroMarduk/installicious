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
#                     installicious.sh and menu_select_role here), where
#                     ESC means exit the installer.
#
# Usage:
#   source lib/manifest.sh
#   source lib/menu.sh
#   ids=$(menu_select_category option "Installicious Options" "Pick what you want.")

# menu_select_category <category> [<title>] [<description>] [<previously_selected>] [<exclude>]
# Multi-select checklist for the given manifest category. Echoes the selected
# IDs on stdout when the user picks NEXT.
#
# If <previously_selected> (space-separated IDs, no quotes) is provided, those
# IDs are pre-checked and any others are unchecked — overriding the manifest's
# II_DEFAULT_SELECTED. This is how options.sh preserves the user's prior
# selections when they navigate BACK and then forward again.
#
# If <exclude> (space-separated IDs) is provided, those IDs are dropped from
# the checklist entirely. Used by pick_packages to hide packages that are
# already required by selected features — those get pulled in via II_DEPS by
# the scheduler regardless, so showing them as toggleable would be misleading.
menu_select_category() {
  local category="$1"
  local title="${2:-Installicious}"
  local desc="${3:-Select items from the ${category} category.}"
  local previously="${4:-}"
  local exclude="${5:-}"

  local use_previously=0
  declare -A on_set=()
  if [[ -n $previously ]]; then
    use_previously=1
    local sel
    for sel in $previously; do
      [[ -n $sel ]] && on_set[$sel]=1
    done
  fi

  declare -A excluded=()
  if [[ -n $exclude ]]; then
    local x
    for x in $exclude; do
      [[ -n $x ]] && excluded[$x]=1
    done
  fi

  local -a items=()
  local id path title_text default
  while IFS= read -r id; do
    # Skip add-on installers — they belong under their parent's sub-menu
    # (see manifest_is_hidden_child / II_OPTIONAL_GROUP).
    manifest_is_hidden_child "$id" && continue
    [[ -n ${excluded[$id]:-} ]] && continue
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

# menu_select_role [<title>] [<description>] [<default_item>]
# First-stage single-select role picker. CANCEL means exit (no previous stage
# to go back to); ESC also exits. If <default_item> is provided and matches a
# role ID, that row is highlighted by default — useful for preserving the
# user's prior pick when they navigate BACK to this screen.
menu_select_role() {
  local title="${1:-Installicious - Pick a Role}"
  local desc="${2:-Pick the role for this Pi. Choose Custom to pick features individually.}"
  local default_item="${3:-}"

  local -a items=()
  local id path title_text desc_text label
  while IFS= read -r id; do
    path=$(role_path_for "$id")
    title_text=$(role_get_field "$path" "ROLE_TITLE")
    desc_text=$(role_get_field "$path" "ROLE_DESCRIPTION")
    # Role picker is the only screen that surfaces the full description —
    # subsequent dialogs (show_required, pick_optional, pick_addons) use
    # the short ROLE_TITLE so the heading stays clean. Whiptail will
    # truncate the item text if it overflows the menu width.
    if [[ -n $desc_text ]]; then
      label="${title_text:-$id} - $desc_text"
    else
      label="${title_text:-$id}"
    fi
    items+=("$id" "$label")
  done < <(role_list_ids | sort)

  if [[ ${#items[@]} -eq 0 ]]; then
    return 2
  fi

  local -a wt_args=(--title "$title" --ok-button "SELECT" --cancel-button "EXIT")
  [[ -n $default_item ]] && wt_args+=(--default-item "$default_item")
  wt_args+=(--menu "$desc" 20 80 12 "${items[@]}")
  whiptail "${wt_args[@]}" 3>&1 1>&2 2>&3
}

# menu_show_required <role_title> <required_id> [<required_id> ...]
# Informational confirmation listing the required features for a role.
# OK forwards (rc=0), BACK rewinds (rc=1), ESC aborts (rc=255).
menu_show_required() {
  local role_title="$1"
  shift
  local message="$role_title will install:"
  local id feature_path feature_title
  for id in "$@"; do
    feature_path=$(manifest_path_for "$id" 2>/dev/null)
    if [[ -n $feature_path ]]; then
      feature_title=$(manifest_get_field "$feature_path" "II_TITLE")
      message+="\n  - $id  ($feature_title)"
    else
      message+="\n  - $id  (no feature manifest found)"
    fi
  done
  message+="\n\nThese are required and will run automatically. Optional add-ons come next."
  whiptail --title "$role_title - Required Features" \
    --yes-button "OK" \
    --no-button "BACK" \
    --yesno "$message" 20 80
}

# menu_pick_optionals <role_title> [--previously <selected>] <optional_id> [<optional_id> ...]
# Multi-select checklist of optional features, all default-off. Echoes the
# selected IDs (space-separated, possibly quoted by whiptail).
#
# Pass --previously "<space-separated-ids>" before the optional ID list to
# pre-check those rows (overriding the default-off baseline). Used by
# options.sh to preserve the user's prior picks when they navigate BACK and
# then forward again.
menu_pick_optionals() {
  local role_title="$1"
  shift
  local previously=""
  local desc="Optional add-ons (default off; pick any you want)."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --previously) previously="$2"; shift 2 ;;
      --desc)       desc="$2";       shift 2 ;;
      *)            break ;;
    esac
  done
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
  local id path feature_title default
  for id in "$@"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    if [[ -n $path ]]; then
      feature_title=$(manifest_get_field "$path" "II_TITLE")
    else
      feature_title=""
    fi
    if [[ $use_previously -eq 1 ]]; then
      [[ -n ${on_set[$id]:-} ]] && default="on" || default="off"
    else
      default="off"
    fi
    items+=("$id" "${feature_title:-$id}" "$default")
  done

  whiptail --title "$role_title - Optional Add-ons" \
    --ok-button "NEXT" \
    --cancel-button "BACK" \
    --checklist "$desc" 20 80 12 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# menu_pick_one_optional <parent_title> [--previously <selected_id>] <child_id> [<child_id> ...]
# Single-select radiolist for sub-features under a parent that declares
# II_OPTIONAL_GROUP_MODE="exclusive" (e.g. webserver -> nginx | apache |
# lighttpd | caddy, mutually exclusive on port 80). Echoes the chosen
# child ID (single value, no quotes) on stdout.
#
# Default selection on first visit comes from each child's
# II_DEFAULT_SELECTED — the first child whose value is "on" wins. If none
# declare "on", the first listed child is selected. Subsequent visits
# (--previously <selected_id>) preserve the user's prior pick across
# back-and-forward navigation.
#
# Return codes follow the same convention as menu_pick_optionals.
menu_pick_one_optional() {
  local parent_title="$1"
  shift
  local previously=""
  if [[ "${1:-}" == "--previously" ]]; then
    previously="$2"
    shift 2
  fi
  if [[ $# -eq 0 ]]; then
    return 2
  fi

  # Resolve the row that should be marked "on". Priority:
  #   1. --previously value (user's prior pick)
  #   2. The first child with II_DEFAULT_SELECTED="on"
  #   3. The first child in the list
  local selected_id=""
  local id path default
  if [[ -n $previously ]]; then
    for id in "$@"; do
      if [[ "$id" == "$previously" ]]; then
        selected_id="$id"
        break
      fi
    done
  fi
  if [[ -z $selected_id ]]; then
    for id in "$@"; do
      path=$(manifest_path_for "$id" 2>/dev/null)
      [[ -z $path ]] && continue
      default=$(manifest_get_field "$path" "II_DEFAULT_SELECTED")
      if [[ $default == "on" ]]; then
        selected_id="$id"
        break
      fi
    done
  fi
  [[ -z $selected_id ]] && selected_id="$1"

  local -a items=()
  local feature_title state
  for id in "$@"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    if [[ -n $path ]]; then
      feature_title=$(manifest_get_field "$path" "II_TITLE")
    else
      feature_title=""
    fi
    if [[ "$id" == "$selected_id" ]]; then
      state="on"
    else
      state="off"
    fi
    items+=("$id" "${feature_title:-$id}" "$state")
  done

  whiptail --title "$parent_title - Pick One" \
    --ok-button "NEXT" \
    --cancel-button "BACK" \
    --radiolist "Pick exactly one. Use SPACE to select, TAB to move to NEXT/BACK." 20 80 12 \
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

# _menu_read_var_chain <var> [--skip-state] <config_file...>
# Sources each config file in a subshell (in order) plus any prior
# state/menu-config.sh, then echoes the value of <var>. The subshell isolates
# the sources from the caller's env. Empty if var is unset after all sources.
#
# --skip-state omits the state/menu-config.sh overlay — useful when the caller
# needs to know what the "baseline" value would be (i.e. what the chain would
# return if no prior menu-config.sh overrides were applied). menu_edit_config
# uses this to skip persisting values that would round-trip to the same thing
# the chain produces on its own.
_menu_read_var_chain() {
  local var="$1"
  shift
  local skip_state=0
  if [[ "${1:-}" == "--skip-state" ]]; then
    skip_state=1
    shift
  fi
  (
    local f
    for f in "$@"; do
      [[ -f $f ]] && source "$f" 2>/dev/null
    done
    if [[ $skip_state -eq 0 ]] \
       && [[ -f "${PATH_STATE:-state}/menu-config.sh" ]]; then
      source "${PATH_STATE:-state}/menu-config.sh" 2>/dev/null
    fi
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
#   _default_<KEY>()  - optional. Echoes the live system value to use as a
#                       DISPLAY fallback when the static config has the key
#                       blank. Read by menu_edit_config only — the value is
#                       not persisted to menu-config.sh unless the user
#                       explicitly edits the row, so "blank means preserve"
#                       semantics stay intact.
#
# When neither _applies_ nor _choices_ is defined, the key is always
# applicable (free-form). _default_ is independent — it only affects the
# initial editor display, not applicability.
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
# Locates <id>'s feature/package manifest, then sources the sibling
# *.choices.sh file (replace .sh suffix) if present so its _choices_*/
# _applies_* functions become available. Side-effect-free: choices files
# define functions only.
_menu_source_choices_for() {
  local id="$1"
  local manifest_path
  manifest_path=$(manifest_path_for "$id" 2>/dev/null) || return 0
  [[ -z $manifest_path ]] && return 0
  local choices_path="${manifest_path%.sh}.choices.sh"
  if [[ -f $choices_path ]]; then
    # shellcheck disable=SC1090
    source "$choices_path"
  fi
}

# menu_edit_config <role_id> <feature_id...>
# Discovers editable keys from the chosen role's ROLE_EDITABLE_CONFIG and each
# selected feature's II_EDITABLE_CONFIG manifest field. Reads default values
# from the corresponding .config files (chained: installicious.config first,
# then per-feature configs, then role config, then any prior menu-config.sh).
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
# Pass role_id="" or "custom" when running the Custom flow (no role config).
menu_edit_config() {
  local role_id="$1"
  shift
  local -a feature_ids=("$@")

  # ---- discover editable keys + their owning labels ----
  #
  # Source order in config_files matters: later entries win in
  # _menu_read_var_chain. To honor "role config overrides feature config",
  # we append per-feature configs first, then the role config last (so
  # role values shadow any colliding feature defaults). The user's
  # menu-config.sh is layered on top of all of these by the chain helper.
  declare -A key_label key_seen
  local -a config_files=("config/installicious.config")
  local key
  local role_config_file=""
  local role_editable=""

  if [[ -n $role_id && $role_id != "custom" ]]; then
    local role_path
    role_path=$(role_path_for "$role_id" 2>/dev/null)
    if [[ -n $role_path ]]; then
      role_config_file=$(role_get_field "$role_path" "ROLE_CONFIG")
      role_editable=$(role_get_field "$role_path" "ROLE_EDITABLE_CONFIG")
      for key in $role_editable; do
        [[ -z $key ]] && continue
        key_seen[$key]=1
        key_label[$key]="role:$role_id"
      done
    fi
  fi

  local id path config_file editable
  for id in "${feature_ids[@]}"; do
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

  # Role config sources LAST so its values win over any colliding feature
  # config defaults (per the "role overrides feature" rule).
  [[ -n $role_config_file && -f $role_config_file ]] && config_files+=("$role_config_file")

  if [[ ${#key_seen[@]} -eq 0 ]]; then
    return 2  # nothing to edit; caller auto-advances
  fi

  # ---- source per-feature choices files for any feature contributing keys ----
  # Each <id> contributing keys gets its install-<id>.choices.sh sourced once
  # so menu_key_applicable + the editor's whiptail-menu rendering can see
  # _choices_<KEY> / _applies_<KEY> functions.
  declare -A sourced_choices
  local owner_id
  for key in "${!key_seen[@]}"; do
    owner_id="${key_label[$key]}"
    owner_id="${owner_id#role:}"  # strip role: prefix if present
    [[ -z $owner_id || $owner_id == "role" ]] && continue
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
  #
  # Display-only runtime fallback: if a key resolves to empty from the
  # config chain AND its choices file defines _default_<KEY>(), call that
  # helper to fetch the live system value (e.g. current timezone, WiFi
  # country). The fallback is purely for what the editor SHOWS — values
  # populated this way are not persisted to menu-config.sh unless the
  # user explicitly edits the row, so "blank == preserve default"
  # semantics stay intact.
  declare -A current default_only
  local val
  for key in "${!key_seen[@]}"; do
    val=$(_menu_read_var_chain "$key" "${config_files[@]}")
    if [[ -z $val ]] && declare -F "_default_$key" >/dev/null; then
      val=$("_default_$key" 2>/dev/null)
      [[ -n $val ]] && default_only[$key]=1
    fi
    current[$key]=$val
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
      items+=("$key" "${current[$key]}")
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
    # per the back-button-everywhere policy (splash + role picker excepted).
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
      new_val=$(whiptail --title "$choice" \
        --default-item "${current[$choice]}" \
        --menu "Select a value for $choice:" 20 80 12 \
        "${choice_items[@]}" \
        3>&1 1>&2 2>&3)
    else
      new_val=$(whiptail --title "$choice" \
        --inputbox "Enter new value for $choice:" \
        10 70 "${current[$choice]}" \
        3>&1 1>&2 2>&3)
    fi
    rc=$?
    # cancel OR ESC on a value-input screen → discard the in-progress edit,
    # return to the editor list (treat ESC like Cancel here, not abort).
    [[ $rc -ne 0 ]] && continue
    current[$choice]="$new_val"
    # The user edited this row — even if they typed the same value the
    # _default_<KEY> helper would return, we now treat it as an explicit
    # choice and persist it.
    unset 'default_only[$choice]'
  done

  # ---- persist to menu-config.sh ----
  local override_file="${PATH_STATE:-state}/menu-config.sh"
  local override_dir
  override_dir=$(dirname "$override_file")
  if [[ ! -d $override_dir ]]; then
    mkdir -p "$override_dir" 2>/dev/null || sudo mkdir -p "$override_dir" || return 1
  fi

  # Skip keys whose values are still the runtime default_only fallback —
  # we don't want a "blank in config means preserve default" key to leak
  # the current system state into menu-config.sh just because the user
  # opened the editor and looked at it. Only the user's actual edits land.
  #
  # Additionally: skip keys whose current value exactly matches what the
  # chain would produce WITHOUT the menu-config.sh overlay. Without this
  # guard, every visit to the editor re-persists every editable key —
  # which is fine when values match, but it ALSO over-persists empty
  # strings when a config file isn't yet wired into the chain (the
  # classic case is a new ROLE_CONFIG: prior runs persist '' overrides,
  # later runs read those '' overrides back even after the role config
  # is in place, masking the real defaults forever). Skipping no-op
  # writes keeps menu-config.sh sparse and recoverable.
  local baseline_val
  {
    echo "# Generated by installicious menu_edit_config — runtime overrides for the current run."
    echo "# Sourced by each installer after its baseline .config files; values here win."
    for key in "${!current[@]}"; do
      [[ -n ${default_only[$key]:-} ]] && continue
      baseline_val=$(_menu_read_var_chain "$key" --skip-state "${config_files[@]}")
      [[ "${current[$key]}" == "$baseline_val" ]] && continue
      printf '%s=%q\n' "$key" "${current[$key]}"
    done
  } > "$override_file" 2>/dev/null || {
    {
      echo "# Generated by installicious menu_edit_config — runtime overrides for the current run."
      echo "# Sourced by each installer after its baseline .config files; values here win."
      for key in "${!current[@]}"; do
        [[ -n ${default_only[$key]:-} ]] && continue
        baseline_val=$(_menu_read_var_chain "$key" --skip-state "${config_files[@]}")
        [[ "${current[$key]}" == "$baseline_val" ]] && continue
        printf '%s=%q\n' "$key" "${current[$key]}"
      done
    } | sudo tee "$override_file" >/dev/null
  }
  return $result_rc
}
