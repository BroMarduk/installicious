#!/bin/bash

# scripts/options.sh - Main menu + scheduler entry point for installicious.
#
# Driven by the manifest registry (lib/manifest.sh): walks the user through
# two whiptail menus (one per category — "option" then "software"), resolves
# any cross-installer dependencies, topo-sorts the queue, and runs each
# installer in order. Replaces the legacy four-script chain
#   options.sh -> software.sh -> process-options.sh -> process-software.sh
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
source lib/menu.sh
source lib/scheduler.sh

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

CURRENTUSER=$(whoami)

# Two-stage menu: options first (system tweaks), then software (packages).
options_selected=$(menu_select_category "option" \
  "Installicious Options" \
  "Select system options to configure.")
options_rc=$?

software_selected=$(menu_select_category "software" \
  "Installicious Software" \
  "Select software packages to install.")
software_rc=$?

# rc=2 means no installers in that category — that's fine, just empty selection.
[[ $options_rc -eq 2 ]] && options_selected=""
[[ $software_rc -eq 2 ]] && software_selected=""

# Whiptail returns IDs space-separated, sometimes quoted. Strip quotes.
selected="${options_selected//\"/} ${software_selected//\"/}"
selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')

if [[ -z $selected ]]; then
  log_info "User $CURRENTUSER continued without selecting any items; nothing to do."
  exit 0
fi

log_info "User $CURRENTUSER selected: $selected."

# shellcheck disable=SC2086
scheduler_run_resolved $selected
rc=$?
case $rc in
  0)              log_ok "Queue completed.";          exit 0 ;;
  $EXIT_REBOOT)   log_info "Queue halted for reboot."; exit $EXIT_REBOOT ;;
  *)              log_warn "Queue completed with errors." "$rc"; exit "$rc" ;;
esac
