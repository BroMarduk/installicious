#!/bin/bash

# scripts/options.sh - Main menu + scheduler entry point.
#
# Driven by a small stage state machine so the user can press BACK at any
# screen to return to the previous one. ESC at any prompt aborts the whole
# flow.
#
# Stages (see the dispatcher at the bottom of the file):
#   pick_task       — single-select task picker (first stage)
#   custom_options  — Custom: pick option-category installers
#   custom_software — Custom: pick software-category installers
#   show_required   — Task: confirm the required installers (info)
#   pick_optional   — Task: pick optional add-ons
#   edit_config     — surface II_EDITABLE_CONFIG / TASK_EDITABLE_CONFIG values
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
source lib/task.sh
source lib/menu.sh
source lib/scheduler.sh
source lib/post_install.sh

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

# Fresh run: clear any stale post-install actions left over from a prior
# interrupted session. (Actions from a queue that included a reboot are still
# preserved across the reboot itself; this only fires on a brand-new run.)
post_install_clear

# Clear stale menu-config overrides from a prior interrupted session. The
# overrides file is intentionally preserved across mid-queue reboots (so user
# edits survive a resume) but should not leak into a brand-new run.
state_clear_menu_overrides

CURRENTUSER=$(whoami)

# State carried across stages.
task_id=""
task_path=""
task_title=""
task_required=""
task_optional=""
options_selected=""
software_selected=""
optional_picked=""
selected=""

# ---------------------------------------------------------------------------
# Stage state machine
# ---------------------------------------------------------------------------
# Helper: figure out which stage precedes edit_config / confirm so BACK from
# the editor or confirm rewinds to the right place.
prev_selection_stage() {
  if [[ $task_id == "custom" ]]; then
    echo "custom_software"
  elif [[ -n $task_optional ]]; then
    echo "pick_optional"
  elif [[ -n $task_required ]]; then
    echo "show_required"
  else
    echo "pick_task"
  fi
}

stage="pick_task"
while true; do
  case "$stage" in

    pick_task)
      task_id=$(menu_select_task "Installicious" \
        "Pick the role for this Pi. Choose Custom to pick installers individually." \
        "$task_id")
      rc=$?
      case $rc in
        0) ;;
        2)
          log_warn "No tasks defined under \$PATH_TASKS; nothing to pick from."
          exit 0
          ;;
        *)
          log_info "User $CURRENTUSER exited at the task picker."
          exit 0
          ;;
      esac
      log_info "User $CURRENTUSER picked task: $task_id."

      if [[ $task_id == "custom" ]]; then
        task_path=""
        task_title="Custom"
        task_required=""
        task_optional=""
        stage="custom_options"
      else
        task_path=$(task_path_for "$task_id")
        task_title=$(task_get_field "$task_path" "TASK_TITLE")
        task_required=$(task_get_field "$task_path" "TASK_INSTALLERS_REQUIRED")
        task_optional=$(task_get_field "$task_path" "TASK_INSTALLERS_OPTIONAL")
        if [[ -n $task_required ]]; then
          stage="show_required"
        elif [[ -n $task_optional ]]; then
          stage="pick_optional"
        else
          # Task with neither required nor optional — degenerate but harmless;
          # treat like custom-with-empty-selection.
          selected=""
          stage="merge_task"
        fi
      fi
      ;;

    custom_options)
      options_selected=$(menu_select_category "option" \
        "Installicious Options" \
        "Select system options to configure." \
        "${options_selected//\"/}")
      rc=$?
      case $rc in
        0)   stage="custom_software" ;;
        1)   stage="pick_task" ;;
        2)   options_selected=""; stage="custom_software" ;;
        255) log_info "User $CURRENTUSER aborted (ESC) at the options picker."; exit 0 ;;
      esac
      ;;

    custom_software)
      software_selected=$(menu_select_category "software" \
        "Installicious Software" \
        "Select software packages to install." \
        "${software_selected//\"/}")
      rc=$?
      case $rc in
        0)   stage="merge_custom" ;;
        1)   stage="custom_options" ;;
        2)   software_selected=""; stage="merge_custom" ;;
        255) log_info "User $CURRENTUSER aborted (ESC) at the software picker."; exit 0 ;;
      esac
      ;;

    merge_custom)
      selected="${options_selected//\"/} ${software_selected//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any installers; nothing to do."
        exit 0
      fi
      stage="edit_config"
      ;;

    show_required)
      # shellcheck disable=SC2086
      menu_show_required "$task_title" $task_required
      rc=$?
      case $rc in
        0)
          if [[ -n $task_optional ]]; then
            stage="pick_optional"
          else
            stage="merge_task"
          fi
          ;;
        1)   stage="pick_task" ;;
        255) log_info "User $CURRENTUSER aborted (ESC) at the required-installers screen."; exit 0 ;;
      esac
      ;;

    pick_optional)
      # shellcheck disable=SC2086
      optional_picked=$(menu_pick_optionals "$task_title" \
        --previously "${optional_picked//\"/}" \
        $task_optional)
      rc=$?
      case $rc in
        0)   stage="merge_task" ;;
        1)
          if [[ -n $task_required ]]; then
            stage="show_required"
          else
            stage="pick_task"
          fi
          ;;
        2)   optional_picked=""; stage="merge_task" ;;
        255) log_info "User $CURRENTUSER aborted (ESC) at the optional picker."; exit 0 ;;
      esac
      ;;

    merge_task)
      selected="$task_required ${optional_picked//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any installers; nothing to do."
        exit 0
      fi
      stage="edit_config"
      ;;

    edit_config)
      log_info "User $CURRENTUSER selected: $selected."
      # shellcheck disable=SC2086
      menu_edit_config "$task_id" $selected
      rc=$?
      case $rc in
        0)   stage="confirm" ;;
        1)   stage=$(prev_selection_stage) ;;
        2)   stage="confirm" ;;  # nothing to edit; auto-advance
        255) log_info "User $CURRENTUSER aborted (ESC) at the config editor."; exit 0 ;;
      esac
      ;;

    confirm)
      confirm_msg="The following installers will run, in dependency order:\n\n  $selected\n\nProceed?"
      menu_confirm "Confirm Install" "$confirm_msg"
      rc=$?
      case $rc in
        0)   stage="run" ;;
        1)   stage="edit_config" ;;
        255) log_info "User $CURRENTUSER aborted (ESC) at the confirmation screen."; exit 0 ;;
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
case $rc in
  0)
    log_ok "Queue completed."
    post_install_apply
    state_clear_menu_overrides
    exit 0
    ;;
  $EXIT_REBOOT)
    # Don't apply yet — resume.sh runs queued commands and emits notes after
    # the queue actually finishes across the reboot. Keep menu-config.sh in
    # place so the resumed installers see the same edits.
    log_info "Queue halted for reboot."
    exit $EXIT_REBOOT
    ;;
  *)
    log_warn "Queue completed with errors." "$rc"
    post_install_apply
    state_clear_menu_overrides
    exit "$rc"
    ;;
esac
