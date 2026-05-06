#!/bin/bash

# scripts/options.sh - Main menu + scheduler entry point.
#
# Driven by a small stage state machine so the user can press BACK at any
# screen to return to the previous one. ESC behaves like BACK on every
# screen EXCEPT the splash (in installicious.sh) and the role picker
# below — at those two, ESC exits the installer.
#
# Stages (see the dispatcher at the bottom of the file):
#   pick_role       — single-select role picker (first stage)
#   custom_options  — Custom: pick option-category features
#   custom_software — Custom: pick software-category features
#   show_required   — Role: confirm the required features (info)
#   pick_optional   — Role: pick optional add-on features
#   pick_addons     — sub-menu(s) for features that declare II_OPTIONAL_GROUP
#                     (skipped automatically when no selected parent has add-ons)
#   edit_config     — surface II_EDITABLE_CONFIG / ROLE_EDITABLE_CONFIG values
#   confirm         — final yes/no
#   run             — scheduler hand-off (terminal stage)
#
# Invoked from installicious.sh after hardware/OS detection and the initial
# whiptail confirmation.

II_TITLE="Installicious Menu"
EXIT_REBOOT=255

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/reboot.sh
source lib/manifest.sh
source lib/role.sh
source lib/menu.sh
source lib/scheduler.sh
source lib/post_install.sh

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

# Pull the OS / Pi-model detection results into scope so per-installer
# choices files (sourced by menu_edit_config) can gate their offerings on
# II_MODEL_NUM, II_CODENAME, II_IS_LITE, etc.
[[ -f "$PATH_STATUS/os.status" ]] && source "$PATH_STATUS/os.status"

# Fresh run: clear any stale post-install actions left over from a prior
# interrupted session. (Actions from a queue that included a reboot are still
# preserved across the reboot itself; this only fires on a brand-new run.)
post_install_clear

# Note: $PATH_STATE/menu-config.sh is intentionally NOT cleared here.
# It persists across runs so user edits (e.g. AccuWeather API key) survive
# without re-typing on every install. To force a reset, the user can:
#   sudo rm $PATH_STATE/menu-config.sh

CURRENTUSER=$(whoami)

# State carried across stages.
role_id=""
role_path=""
role_title=""
role_required=""
role_optional=""
options_selected=""
software_selected=""
optional_picked=""
selected=""           # final list (parents + their picked add-ons)
selected_parents=""   # the user's category/role picks BEFORE add-ons get merged
declare -A addons_picked   # parent_id → space-separated add-on IDs the user picked

# Tracks the stage we just left, so stages that auto-advance on rc=2 (e.g.
# edit_config when no keys are editable) can detect a back-from-confirm
# bounce and rewind further instead of trapping the user on confirm.
prev_stage=""

# ---------------------------------------------------------------------------
# Stage state machine
# ---------------------------------------------------------------------------
# Helper: figure out which stage precedes edit_config / confirm so BACK from
# the editor or confirm rewinds to the right place. If any selected parent
# has an II_OPTIONAL_GROUP, the most recent selection stage is pick_addons.
_any_parent_has_addons() {
  local id ppath addons
  for id in $selected_parents; do
    ppath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $ppath ]] && continue
    addons=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
    [[ -n $addons ]] && return 0
  done
  return 1
}
# True for the Custom role and any role that declares no required / optional
# features (the stubbed roles today: homeassistant, mediaserver, pihole,
# weewx). Both flow through the per-feature checklist (custom_options →
# custom_software) instead of show_required / pick_optional.
_role_uses_custom_flow() {
  [[ $role_id == "custom" ]] && return 0
  [[ -z $role_required && -z $role_optional ]] && return 0
  return 1
}
prev_selection_stage() {
  if _any_parent_has_addons; then
    echo "pick_addons"
  elif _role_uses_custom_flow; then
    echo "custom_software"
  elif [[ -n $role_optional ]]; then
    echo "pick_optional"
  elif [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}
# What pick_addons rewinds to (the same logic as prev_selection_stage but
# without considering pick_addons itself).
_pre_addons_stage() {
  if _role_uses_custom_flow; then
    echo "custom_software"
  elif [[ -n $role_optional ]]; then
    echo "pick_optional"
  elif [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}

stage="pick_role"
_entry_stage=""
while true; do
  prev_stage="$_entry_stage"
  _entry_stage="$stage"
  case "$stage" in

    pick_role)
      log_info "Rendering role picker."
      role_id=$(menu_select_role "Installicious" \
        "Pick the role for this Pi. Choose Custom to pick features individually." \
        "$role_id")
      rc=$?
      case $rc in
        0) ;;
        2)
          log_warn "No roles defined under \$PATH_ROLES; nothing to pick from."
          exit 0
          ;;
        *)
          log_info "User $CURRENTUSER exited at the role picker."
          exit 0
          ;;
      esac
      log_info "User $CURRENTUSER picked role: $role_id."

      if [[ $role_id == "custom" ]]; then
        role_path=""
        role_title="Custom"
        role_required=""
        role_optional=""
        stage="custom_options"
      else
        role_path=$(role_path_for "$role_id")
        role_title=$(role_get_field "$role_path" "ROLE_TITLE")
        role_required=$(role_get_field "$role_path" "ROLE_FEATURES_REQUIRED")
        role_optional=$(role_get_field "$role_path" "ROLE_FEATURES_OPTIONAL")
        if [[ -n $role_required ]]; then
          stage="show_required"
        elif [[ -n $role_optional ]]; then
          stage="pick_optional"
        else
          # Role with neither required nor optional features — the stubbed
          # roles today (homeassistant, mediaserver, pihole, weewx) take
          # this branch. Behave like Custom: drop into the per-feature
          # picker so the user can still build a queue. Once a stub gains
          # real ROLE_FEATURES_REQUIRED/OPTIONAL it'll route through
          # show_required / pick_optional like a populated role.
          log_info "Role $role_id has no required/optional features defined; routing to per-feature picker."
          stage="custom_options"
        fi
      fi
      ;;

    custom_options)
      log_info "Rendering options checklist."
      options_selected=$(menu_select_category "option" \
        "Installicious Options" \
        "Select system options to configure." \
        "${options_selected//\"/}")
      rc=$?
      case $rc in
        0)     stage="custom_software" ;;
        1|255) stage="pick_role" ;;          # BACK or ESC → previous stage
        2)     options_selected=""; stage="custom_software" ;;
      esac
      ;;

    custom_software)
      log_info "Rendering software checklist."
      software_selected=$(menu_select_category "software" \
        "Installicious Software" \
        "Select software packages to install." \
        "${software_selected//\"/}")
      rc=$?
      case $rc in
        0)     stage="merge_custom" ;;
        1|255) stage="custom_options" ;;     # BACK or ESC → previous stage
        2)     software_selected=""; stage="merge_custom" ;;
      esac
      ;;

    merge_custom)
      selected="${options_selected//\"/} ${software_selected//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any features; nothing to do."
        exit 0
      fi
      selected_parents="$selected"
      if _any_parent_has_addons; then
        stage="pick_addons"
      else
        stage="edit_config"
      fi
      ;;

    show_required)
      log_info "Rendering required-features confirmation for role $role_id."
      # shellcheck disable=SC2086
      menu_show_required "$role_title" $role_required
      rc=$?
      case $rc in
        0)
          if [[ -n $role_optional ]]; then
            stage="pick_optional"
          else
            stage="merge_role"
          fi
          ;;
        1|255) stage="pick_role" ;;          # BACK or ESC → role picker
      esac
      ;;

    pick_optional)
      log_info "Rendering optional-features picker for role $role_id."
      # shellcheck disable=SC2086
      optional_picked=$(menu_pick_optionals "$role_title" \
        --previously "${optional_picked//\"/}" \
        $role_optional)
      rc=$?
      case $rc in
        0)     stage="merge_role" ;;
        1|255)
          if [[ -n $role_required ]]; then
            stage="show_required"
          else
            stage="pick_role"
          fi
          ;;
        2)     optional_picked=""; stage="merge_role" ;;
      esac
      ;;

    merge_role)
      selected="$role_required ${optional_picked//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any features; nothing to do."
        exit 0
      fi
      selected_parents="$selected"
      if _any_parent_has_addons; then
        stage="pick_addons"
      else
        stage="edit_config"
      fi
      ;;

    pick_addons)
      log_info "Rendering add-on sub-menus."
      # Walk each currently-selected installer; if it declares
      # II_OPTIONAL_GROUP, surface its add-ons as a checklist sub-menu.
      # User's picks for each parent are remembered in addons_picked so
      # back-nav re-presents them pre-checked.
      _rewind=0
      for parent_id in $selected_parents; do
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        [[ -z $ppath ]] && continue
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        [[ -z $pchildren ]] && continue
        ptitle=$(manifest_get_field "$ppath" "II_TITLE")

        # shellcheck disable=SC2086
        picked=$(menu_pick_optionals "$ptitle" \
          --previously "${addons_picked[$parent_id]:-}" \
          $pchildren)
        rc=$?
        case $rc in
          0)     addons_picked[$parent_id]="${picked//\"/}" ;;
          1|255) _rewind=1; break ;;
          2)     ;;
        esac
      done

      if [[ $_rewind -eq 1 ]]; then
        stage=$(_pre_addons_stage)
        continue
      fi

      # Rebuild `selected` from `selected_parents` + currently-picked add-ons
      # for each. Always start from selected_parents so a back-and-forward
      # trip never duplicates or carries over add-ons of a since-deselected
      # parent.
      _merged="$selected_parents"
      for parent_id in $selected_parents; do
        _merged="$_merged ${addons_picked[$parent_id]:-}"
      done
      selected=$(echo "$_merged" | tr -s ' ' | sed 's/^ //; s/ $//')
      log_info "User $CURRENTUSER add-ons merged: $selected."
      stage="edit_config"
      ;;

    edit_config)
      log_info "User $CURRENTUSER selected: $selected."
      # shellcheck disable=SC2086
      menu_edit_config "$role_id" $selected
      rc=$?
      # menu_edit_config now translates ESC to rc=1 internally (with edits
      # persisted, same as the BACK button), so the explicit 255 case is
      # only there as belt-and-suspenders if a future helper change leaks
      # 255 through.
      case $rc in
        0)     stage="confirm" ;;
        1|255) stage=$(prev_selection_stage) ;;
        2)
          # No editable keys for the current selection. Auto-advance — but
          # if the user just pressed BACK on confirm, going forward to
          # confirm again creates an infinite bounce. Rewind further in
          # that case instead.
          if [[ $prev_stage == "confirm" ]]; then
            stage=$(prev_selection_stage)
          else
            stage="confirm"
          fi
          ;;
      esac
      ;;

    confirm)
      log_info "Rendering install confirmation."
      confirm_msg="The following features will run, in dependency order:\n\n  $selected\n\nProceed?"
      menu_confirm "Confirm Install" "$confirm_msg"
      rc=$?
      case $rc in
        0)     stage="run" ;;
        1|255) stage="edit_config" ;;  # BACK or ESC → editor
      esac
      ;;

    run)
      break
      ;;

    *)
      log_warn "Unknown stage: $stage; aborting."
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Run via scheduler
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
scheduler_run_resolved $selected
rc=$?
# menu-config.sh is intentionally preserved across runs so the user's edits
# (API keys, hostnames, etc.) don't have to be re-typed every install. Reset
# manually with `sudo rm $PATH_STATE/menu-config.sh` if desired.
case $rc in
  0)
    log_ok "Queue completed."
    post_install_apply
    exit 0
    ;;
  3)
    # Pre-flight validation rejected the queue (missing dep installer or
    # similar). No state was changed; surface to the user and exit cleanly.
    msg="${SCHEDULER_LAST_ERROR:-Pre-flight validation failed.}\n\nNothing was installed. Aborting."
    whiptail --title "Installicious — Cannot start queue" --msgbox "$msg" 14 78
    exit 3
    ;;
  $EXIT_REBOOT)
    # Don't apply yet — resume.sh runs queued commands and emits notes after
    # the queue actually finishes across the reboot. menu-config.sh is kept
    # in place so the resumed installers see the same edits.
    log_info "Queue halted for reboot."
    exit $EXIT_REBOOT
    ;;
  *)
    log_warn "Queue completed with errors." "$rc"
    post_install_apply
    exit "$rc"
    ;;
esac
