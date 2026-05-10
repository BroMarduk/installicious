#!/bin/bash

# Module:      SkyfieldAlmanac WeeWX Extension Installer
# Description: Installs the SkyfieldAlmanac extension for WeeWX. Provides
#              high-precision astronomical data (sunrise/set, moon phase,
#              planet positions, etc.) by replacing weewx's built-in pyephem
#              calculations with the Skyfield library.
#
#              Steps:
#                1. Install three apt packages (numpy, pandas, python3-skyfield).
#                   Pre-install state is recorded per package so --uninstall
#                   only removes packages we put in place.
#                2. Clone (or refresh) the SkyfieldAlmanac repo to a working
#                   directory under $PATH_BACKUP/skyfield-source.
#                3. Run `wee_extension --install <dir>` to register with weewx.
#
#              --uninstall reverses in opposite order:
#                1. wee_extension --uninstall (best-effort; weewx may already
#                   be gone if the user pulled it).
#                2. Remove the cloned source tree.
#                3. apt-remove the python packages we installed (per-package
#                   pre-state check leaves anything that was already there).
#
#              II_DEPS="weewx" so the scheduler auto-pulls weewx into the
#              queue (and with the hardened scheduler will refuse to start if
#              the weewx installer is missing entirely).
#
#              v1 caveats: extension name "SkyfieldAlmanac" is hardcoded for
#              the wee_extension --uninstall step; if upstream renames the
#              extension, update SKYFIELD_EXTENSION_NAME below.

# === II_MANIFEST_BEGIN ===
II_ID="skyfield"
II_TITLE="SkyfieldAlmanac (WeeWX extension)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="weewx"
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="python3-numpy python3-pandas python3-skyfield"
II_RESTRICT_TO_ROLES="weewx"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh

SKYFIELD_REPO_URL="${SKYFIELD_REPO_URL:-https://github.com/Jterrettaz/SkyfieldAlmanac.git}"
SKYFIELD_EXTENSION_NAME="${SKYFIELD_EXTENSION_NAME:-SkyfieldAlmanac}"
SKYFIELD_SRC_DIR="${SKYFIELD_SRC_DIR:-${PATH_BACKUP:-backup}/skyfield-source}"
WEE_EXTENSION_BIN="${WEE_EXTENSION_BIN:-/usr/bin/wee_extension}"

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

STATUS_FILE=$(status_file_for "$II_ID")

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "SkyfieldAlmanac already installed at recorded version. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # Step 1: apt deps (with per-package pre-state for symmetric uninstall).
  log_info "Ensuring apt deps: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt deps install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install SkyfieldAlmanac apt dependencies. Error Code: $rc."
    return $rc
  fi

  # Step 2: fetch source. Need git for this; pull it in if not already there.
  installer_apt_ensure_deps git
  rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "git not available (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not ensure git was installed for SkyfieldAlmanac. Error Code: $rc."
    return $rc
  fi

  log_info "Fetching SkyfieldAlmanac source into $SKYFIELD_SRC_DIR."
  if [[ -d "$SKYFIELD_SRC_DIR/.git" ]]; then
    if ! sudo git -C "$SKYFIELD_SRC_DIR" pull --ff-only; then
      log_warn "git pull failed; re-cloning from scratch."
      sudo rm -rf "$SKYFIELD_SRC_DIR"
    fi
  fi
  if [[ ! -d "$SKYFIELD_SRC_DIR/.git" ]]; then
    sudo mkdir -p "$(dirname "$SKYFIELD_SRC_DIR")"
    if ! sudo git clone "$SKYFIELD_REPO_URL" "$SKYFIELD_SRC_DIR"; then
      log_fail "Failed to clone $SKYFIELD_REPO_URL."
      status_mark_failed "$II_ID" "git clone failed"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not clone the SkyfieldAlmanac source."
      return 1
    fi
  fi
  status_set "$STATUS_FILE" "SKYFIELD_FW_SRC_DIR" "$SKYFIELD_SRC_DIR"

  # Step 3: register with weewx via wee_extension.
  if [[ ! -x "$WEE_EXTENSION_BIN" ]]; then
    log_fail "wee_extension not found at $WEE_EXTENSION_BIN; is weewx installed?"
    status_mark_failed "$II_ID" "wee_extension binary missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not find wee_extension; is WeeWX installed?"
    return 1
  fi

  # wee_extension --install behavior on an already-registered extension
  # varies by weewx version (some overwrite silently, some prompt, some
  # error). Soft-fail rather than hard-fail: a non-zero exit when the
  # extension is already registered shouldn't tank the rest of the queue.
  # If the user really wants a clean re-register, the manual recipe is:
  #   sudo wee_extension --uninstall SkyfieldAlmanac
  #   sudo bash installicious.sh   # re-runs through skyfield cleanly
  log_info "Registering extension with weewx: $WEE_EXTENSION_BIN --install $SKYFIELD_SRC_DIR"
  if ! sudo "$WEE_EXTENSION_BIN" --install "$SKYFIELD_SRC_DIR"; then
    log_warn "wee_extension --install returned non-zero. The extension may already be registered, or there may be a real error. Verify with: sudo $WEE_EXTENSION_BIN --list"
    echo -e "[ \e[0;33mWARN\e[0m ] wee_extension --install returned non-zero — check 'wee_extension --list' to confirm SkyfieldAlmanac is registered."
  fi

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "SkyfieldAlmanac installed and registered with WeeWX."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed SkyfieldAlmanac."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "SkyfieldAlmanac already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] SkyfieldAlmanac is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for skyfield; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # Step 1: unregister extension. Best-effort: weewx may have been removed.
  if [[ -x "$WEE_EXTENSION_BIN" ]]; then
    log_info "Unregistering extension: $WEE_EXTENSION_BIN --uninstall $SKYFIELD_EXTENSION_NAME"
    sudo "$WEE_EXTENSION_BIN" --uninstall "$SKYFIELD_EXTENSION_NAME" \
      || log_warn "wee_extension --uninstall returned non-zero (continuing)."
  else
    log_info "wee_extension not present; skipping extension unregister (weewx likely already removed)."
  fi

  # Step 2: remove the cloned source tree.
  local recorded_src
  recorded_src=$(status_get "$STATUS_FILE" "SKYFIELD_FW_SRC_DIR")
  [[ -z $recorded_src ]] && recorded_src="$SKYFIELD_SRC_DIR"
  if [[ -d $recorded_src ]]; then
    log_info "Removing source tree at $recorded_src."
    sudo rm -rf "$recorded_src" || log_warn "rm of $recorded_src returned non-zero."
  fi

  # Step 3: revert apt packages we installed.
  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "SkyfieldAlmanac uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled SkyfieldAlmanac."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
