#!/bin/bash

# Module:      log2ram (apt package wrapper)
# Description: Installs the log2ram apt package, which mounts /var/log
#              as a RAM-backed filesystem (tmpfs OR a zram block device,
#              depending on log2ram.conf's ZL2R setting) with optional
#              periodic / on-shutdown sync to disk.
#
#              feature-ram-logging configures the actual behavior; this
#              package only ensures log2ram is installable and installed.
#
# Repo handling:
#   - Trixie (Debian 13) and forward: log2ram lives in main, plain
#     `apt install log2ram` works.
#   - Bookworm (Debian 12) and older: log2ram isn't in main. We need
#     the azlux third-party repo:
#         http://packages.azlux.fr/debian/
#     On these systems we install the keyring + sources.list.d entry
#     before the apt install. On uninstall, if we added the repo we
#     clean it up too.
#
# Pre-install state for the apt package itself is handled by
# lib/installer_apt — this file only adds the repo dance around it.

# === II_MANIFEST_BEGIN ===
II_ID="log2ram"
II_TITLE="log2ram (RAM-backed /var/log)"
II_CATEGORY="package"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="log2ram"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

STATUS_FILE=$(status_file_for "$II_ID")

AZLUX_LIST="/etc/apt/sources.list.d/azlux.list"
AZLUX_KEYRING="/usr/share/keyrings/azlux-archive-keyring.gpg"

_os_version_id() {
  [[ -r /etc/os-release ]] || { echo 0; return 0; }
  awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release
}

_log2ram_in_main_repo() {
  # Returns 0 (true) if log2ram is in the OS's main repo, 1 if we need azlux.
  local v
  v=$(_os_version_id)
  [[ -z $v ]] && return 1
  (( ${v%%.*} >= 13 )) && return 0
  return 1
}

# Returns 0 if we just added the azlux repo, 1 if it was already there or
# if we didn't need it.
_ensure_azlux_repo() {
  if _log2ram_in_main_repo; then
    # Trixie+: clean up any stale azlux from a prior Bookworm install.
    if [[ -f $AZLUX_LIST ]]; then
      log_info "OS has log2ram in main; removing stale azlux repo."
      sudo rm -f "$AZLUX_LIST" "$AZLUX_KEYRING"
      sudo apt-get update 2>/dev/null || true
      status_set "$STATUS_FILE" "LOG2RAM_FW_AZLUX_ADDED" "false"
    fi
    return 1
  fi
  if [[ -f $AZLUX_LIST ]]; then
    log_info "azlux repo already present."
    return 1
  fi
  log_info "Adding azlux third-party repo for log2ram (OS not Trixie+)."
  if ! sudo wget -qO "$AZLUX_KEYRING" https://azlux.fr/repo.gpg; then
    log_warn "Failed to fetch azlux GPG key; log2ram install will likely fail."
    return 1
  fi
  echo "deb [signed-by=$AZLUX_KEYRING] http://packages.azlux.fr/debian/ stable main" \
    | sudo tee "$AZLUX_LIST" >/dev/null
  sudo apt-get update 2>/dev/null || true
  status_set "$STATUS_FILE" "LOG2RAM_FW_AZLUX_ADDED" "true"
  return 0
}

_remove_azlux_repo_if_we_added_it() {
  local added
  added=$(status_get "$STATUS_FILE" "LOG2RAM_FW_AZLUX_ADDED" 2>/dev/null)
  [[ $added != "true" ]] && return 0
  if [[ -f $AZLUX_LIST ]]; then
    log_info "Removing azlux repo (we added it during install)."
    sudo rm -f "$AZLUX_LIST" "$AZLUX_KEYRING"
    sudo apt-get update 2>/dev/null || true
  fi
}

# Wrap installer_apt_main with the repo setup/teardown. Mode parsing
# duplicates a tiny bit of installer_apt's logic but keeps the wrapper
# simple — repo setup runs before install, repo cleanup runs after
# uninstall.
case "$1" in
  --uninstall)
    installer_apt_main "$@"
    rc=$?
    _remove_azlux_repo_if_we_added_it
    exit $rc
    ;;
  *)
    _ensure_azlux_repo
    installer_apt_main "$@"
    exit $?
    ;;
esac
