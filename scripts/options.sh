#!/bin/bash

# scripts/options.sh - Main menu + scheduler entry point.
#
# Flow:
#   1. Task picker         (single-select whiptail over $PATH_TASKS)
#   2a. If task=custom:    fall through to per-installer category menus
#   2b. Otherwise:         show required installers (msgbox) → optional picker
#                          (default-off checklist)
#   3. Config editor       (menu_edit_config — Phase 2; no-op if no editable keys)
#   4. Confirmation        (yes/no msgbox)
#   5. Run via scheduler   (scheduler_run_resolved)
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

# ---------------------------------------------------------------------------
# Stage 1: Task picker
# ---------------------------------------------------------------------------
task_id=$(menu_select_task "Installicious" \
  "Pick the role for this Pi. Choose Custom to pick installers individually.")
task_rc=$?
if [[ $task_rc -eq 2 ]]; then
  log_warn "No tasks defined under \$PATH_TASKS; nothing to pick from."
  exit 0
fi
if [[ $task_rc -ne 0 || -z $task_id ]]; then
  log_info "User $CURRENTUSER cancelled the task picker."
  exit 0
fi
log_info "User $CURRENTUSER picked task: $task_id"

# ---------------------------------------------------------------------------
# Stage 2a: Custom — fall through to per-installer category menus
# ---------------------------------------------------------------------------
if [[ $task_id == "custom" ]]; then
  options_selected=$(menu_select_category "option" \
    "Installicious Options" \
    "Select system options to configure.")
  options_rc=$?
  software_selected=$(menu_select_category "software" \
    "Installicious Software" \
    "Select software packages to install.")
  software_rc=$?
  [[ $options_rc -eq 2 ]] && options_selected=""
  [[ $software_rc -eq 2 ]] && software_selected=""
  selected="${options_selected//\"/} ${software_selected//\"/}"
else
  # -------------------------------------------------------------------------
  # Stage 2b: Task — show required installers, then optional picker
  # -------------------------------------------------------------------------
  task_path=$(task_path_for "$task_id")
  task_title=$(task_get_field "$task_path" "TASK_TITLE")
  task_required=$(task_get_field "$task_path" "TASK_INSTALLERS_REQUIRED")
  task_optional=$(task_get_field "$task_path" "TASK_INSTALLERS_OPTIONAL")

  if [[ -n $task_required ]]; then
    # shellcheck disable=SC2086
    menu_show_required "$task_title" $task_required
  fi

  optional_picked=""
  if [[ -n $task_optional ]]; then
    # shellcheck disable=SC2086
    optional_picked=$(menu_pick_optionals "$task_title" $task_optional)
    optional_rc=$?
    if [[ $optional_rc -ne 0 ]]; then
      log_info "User $CURRENTUSER cancelled at the optional picker."
      exit 0
    fi
  fi

  selected="$task_required ${optional_picked//\"/}"
fi

# Normalize whitespace.
selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')

if [[ -z $selected ]]; then
  log_info "User $CURRENTUSER continued without selecting any installers; nothing to do."
  exit 0
fi

log_info "User $CURRENTUSER selected: $selected."

# ---------------------------------------------------------------------------
# Stage 3: Config editor (Phase 2)
# ---------------------------------------------------------------------------
# Surfaces editable keys advertised by the chosen task and selected installers.
# Defaults are read from the corresponding .config files; user edits persist to
# $PATH_STATE/menu-config.sh and are sourced by each installer at run time.
# No-op if no editable keys are advertised.
# shellcheck disable=SC2086
menu_edit_config "$task_id" $selected

# ---------------------------------------------------------------------------
# Stage 4: Confirmation
# ---------------------------------------------------------------------------
confirm_msg="The following installers will run, in dependency order:\n\n  $selected\n\nProceed?"
if ! menu_confirm "Confirm Install" "$confirm_msg"; then
  log_info "User $CURRENTUSER cancelled at confirmation."
  state_clear_menu_overrides
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage 5: Run via scheduler
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
