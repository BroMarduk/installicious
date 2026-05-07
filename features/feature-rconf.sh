#!/bin/bash

# Module:      Raspberry Pi Configuration
# Description: Hands the terminal off to the canonical `raspi-config`
#              interactive UI so the user picks their settings there
#              directly, then returns to installicious to continue the
#              queue. This sidesteps the maintenance burden of mirroring
#              raspi-config's option list, version-specific differences
#              (do_overscan vs do_overscan_kms, do_serial vs do_serial_pi5,
#              GPU memory split removal, etc.), and Lite-vs-Desktop
#              gating — whatever raspi-config has is what the user sees,
#              auto-updated with every Pi OS release.
#
#              Reboot detection: hash /boot/firmware/config.txt and
#              /boot/firmware/cmdline.txt before and after the user's
#              raspi-config session. Any change to those files means a
#              reboot is required (every reboot-needing rconf change
#              writes one of them). If raspi-config triggers its own
#              reboot ("reboot now? [Yes]"), our process is killed
#              mid-installer; we advance the queue cursor BEFORE shelling
#              out so the systemd-resume picks up after rconf rather than
#              re-prompting it.
#
#              Items the user picks in raspi-config are independent of
#              installicious's config-editor mechanism — there's no
#              II_EDITABLE_CONFIG, no rconf.config, no choices file.
#              The user's choices live in /boot/firmware/config.txt,
#              /etc/default/keyboard, etc., maintained by raspi-config.
#
#              Imager-handled inputs (timezone, Wi-Fi country, hostname,
#              SSH enable, initial user/password, RPi Connect) are NOT
#              touched here — set them at flash time via the Pi Imager.
#
#              Bump II_VERSION to force a re-prompt on the next run.

# === II_MANIFEST_BEGIN ===
II_ID="rconf"
II_TITLE="Raspberry Pi Configuration (raspi-config)"
II_CATEGORY="option"
II_VERSION="3"
II_DEPS=""
II_REQUIRES_REBOOT="conditional"
II_DEFAULT_SELECTED="off"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/reboot.sh

EXIT_REBOOT=255

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

# Boot config files — the canonical reboot-required signals. Modern Pi OS
# (Bookworm+) uses /boot/firmware/; the /boot/ fallback is legacy-image
# insurance for any straggler systems.
if [[ -e /boot/firmware/config.txt ]]; then
  BOOT_CONFIG="/boot/firmware/config.txt"
  BOOT_CMDLINE="/boot/firmware/cmdline.txt"
else
  BOOT_CONFIG="/boot/config.txt"
  BOOT_CMDLINE="/boot/cmdline.txt"
fi

# _hash_boot_files - echoes a sha256 hash combining both boot config files.
# Returns empty if neither file exists (in which case we treat as unchanged).
_hash_boot_files() {
  local h_config="-" h_cmdline="-"
  [[ -f $BOOT_CONFIG ]]  && h_config=$(sha256sum  "$BOOT_CONFIG"  | awk '{print $1}')
  [[ -f $BOOT_CMDLINE ]] && h_cmdline=$(sha256sum "$BOOT_CMDLINE" | awk '{print $1}')
  echo "${h_config}:${h_cmdline}"
}

do_install() {
  status_mark_started "$II_ID"

  # Make sure raspi-config is present. The package is preinstalled on Pi OS
  # but Lite minimal images and bare Debian on Pi can lack it.
  apt_ensure_installed raspi-config
  if [[ $? -ne 0 ]]; then
    log_fail "Could not ensure raspi-config is installed."
    status_mark_failed "$II_ID" "raspi-config install failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install raspi-config."
    return 1
  fi
  if [[ ! -x /usr/bin/raspi-config ]]; then
    log_fail "raspi-config not found at /usr/bin/raspi-config."
    status_mark_failed "$II_ID" "raspi-config missing after install"
    echo -e "[ \e[0;31mFAIL\e[0m ] raspi-config is not present."
    return 1
  fi

  # Advance the scheduler cursor past rconf BEFORE handing off, so a user
  # who picks "reboot now? [Yes]" inside raspi-config doesn't loop back
  # into rconf when systemd-resume picks the queue up after the reboot.
  if declare -F state_load >/dev/null && declare -F state_save_cursor >/dev/null \
     && state_exists; then
    state_load 2>/dev/null
    if [[ -n ${II_QUEUE_CURSOR:-} ]]; then
      state_save_cursor "$((II_QUEUE_CURSOR + 1))"
      log_info "Advanced queue cursor past rconf in case raspi-config triggers a reboot."
    fi
  fi

  # Snapshot the boot files so we can detect a reboot-required change after
  # raspi-config exits.
  local hash_before
  hash_before=$(_hash_boot_files)

  # Hand the terminal over to raspi-config interactively. This blocks until
  # the user exits raspi-config (or until raspi-config calls `reboot` if
  # the user picks "reboot now").
  log_info "Handing off to raspi-config — return to installicious when done."
  echo
  echo "============================================================"
  echo "  Handing off to raspi-config (interactive)."
  echo "  Make your changes, then exit raspi-config to return here."
  echo "============================================================"
  echo
  sudo raspi-config
  local rc=$?
  log_info "raspi-config exited with rc=$rc."

  # Compare boot file hashes — any change means a reboot is required.
  local hash_after
  hash_after=$(_hash_boot_files)

  if [[ $hash_before != "$hash_after" ]]; then
    log_info "Boot config files changed during raspi-config session — reboot required."
    status_mark_complete "$II_ID" "$II_VERSION"
    echo -e "[  \e[0;32mOK\e[0m  ] raspi-config changes recorded; reboot will be triggered to apply."
    request_reboot "raspi-config changes need a reboot to take effect" "$II_ID"
    return $EXIT_REBOOT
  fi

  # /var/run/reboot-required is the Debian-wide reboot-required marker.
  # raspi-config doesn't set it directly, but apt operations triggered
  # by some raspi-config actions (e.g. installing a kernel module) do.
  if [[ -f /var/run/reboot-required ]]; then
    log_info "/var/run/reboot-required present — reboot required."
    status_mark_complete "$II_ID" "$II_VERSION"
    echo -e "[  \e[0;32mOK\e[0m  ] raspi-config changes recorded; reboot will be triggered to apply."
    request_reboot "system flagged reboot-required during raspi-config" "$II_ID"
    return $EXIT_REBOOT
  fi

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "raspi-config session complete; no reboot needed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully completed Pi configuration."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "rconf already marked uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] rconf is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for rconf; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # raspi-config doesn't have a clean "undo my changes" path — the user's
  # selections become baseline system state. Mark uninstalled for record-
  # keeping and tell the user to re-run raspi-config if they want to
  # adjust settings.
  log_info "rconf changes live in /boot/firmware/config.txt etc.; raspi-config has no undo. To change settings, re-run raspi-config directly."
  status_mark_uninstalled "$II_ID"
  echo -e "[  \e[0;32mOK\e[0m  ] rconf marked uninstalled. Run raspi-config directly to adjust settings."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
