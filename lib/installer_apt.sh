#!/bin/bash

# lib/installer_apt.sh — Driver + helper for apt-package installers.
#
# Two entry points, for two different cases:
#
# 1) Apt-only installer (the entire job is "ensure these apt packages are
#    installed"). Drop in a thin installers/install-<id>.sh:
#
#      #!/bin/bash
#      # === II_MANIFEST_BEGIN ===
#      II_ID="htop"
#      II_TITLE="htop process viewer"
#      II_CATEGORY="software"
#      II_VERSION="1"
#      II_DEPS=""
#      II_REQUIRES_REBOOT="never"
#      II_APT_PACKAGES="htop"
#      # === II_MANIFEST_END ===
#
#      source lib/installer_apt.sh
#      installer_apt_main "$@"
#
#    `II_APT_PACKAGES` is space-separated. Pre-install state is recorded per
#    package so --uninstall only removes packages we put in place.
#
# 2) Non-trivial installer that also needs apt deps. Inside its body:
#
#      installer_apt_ensure_deps $II_APT_PACKAGES
#
#    Idempotent best-effort install of each package; no per-package state
#    tracking (parent installer is responsible for any custom uninstall).

source config/installicious.config 2>/dev/null || true
source lib/log.sh    2>/dev/null
source lib/status.sh 2>/dev/null
source lib/apt.sh    2>/dev/null

# installer_apt_main "$@"
# Full lifecycle for an apt-only installer. Reads II_ID, II_TITLE, II_VERSION,
# and II_APT_PACKAGES from the caller's environment (set by sourcing the
# manifest block at the top of the installer file). Parses --install /
# --uninstall and dispatches.
installer_apt_main() {
  local mode="install"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install)   mode="install" ;;
      --uninstall) mode="uninstall" ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done

  local FILE_LOG_INSTALLER
  if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
    FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
  else
    FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
  fi
  log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

  if [[ -z ${II_APT_PACKAGES:-} ]]; then
    log_fail "installer_apt_main: II_APT_PACKAGES is empty for $II_ID; nothing to install."
    return 2
  fi

  if [[ $mode == "install" ]]; then
    _installer_apt_do_install
  else
    _installer_apt_do_uninstall
  fi
}

# installer_apt_ensure_deps <pkg> [<pkg>...]
# Idempotent ensure-installed for one or more apt packages. Stops and returns
# non-zero on the first failure. No state tracking — for use inside non-trivial
# installer bodies that just need their apt prerequisites in place.
installer_apt_ensure_deps() {
  local pkg rc
  for pkg in "$@"; do
    [[ -z $pkg ]] && continue
    apt_ensure_installed "$pkg"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      log_fail "Failed to install apt dependency: $pkg." "$rc"
      return $rc
    fi
  done
  return 0
}

# Derive a deterministic status-file variable name for a package's
# pre-install state. Examples:
#   "git"          → "GIT_FW_PRE_INSTALLED"
#   "python3-pip"  → "PYTHON3_PIP_FW_PRE_INSTALLED"
_installer_apt_pre_var() {
  local pkg="$1"
  local upper
  upper=$(echo "$pkg" | tr 'a-z-' 'A-Z_')
  echo "${upper}_FW_PRE_INSTALLED"
}

# installer_apt_record_install <status_file> <pkg> [<pkg>...]
# For each package: record pre-install state (true if already there, false if
# we'll be the one to install it), then ensure-install via apt. Stops and
# returns non-zero on the first install failure.
#
# Bespoke installers (with custom bodies, not using installer_apt_main) can
# call this to get the same per-package symmetric tracking that the full
# driver provides, then layer their own logic on top.
installer_apt_record_install() {
  local status_file="$1"
  shift
  local pkg pre_var rc
  for pkg in "$@"; do
    [[ -z $pkg ]] && continue
    pre_var=$(_installer_apt_pre_var "$pkg")
    if apt_is_installed "$pkg"; then
      status_set "$status_file" "$pre_var" "true"
    else
      status_set "$status_file" "$pre_var" "false"
    fi
    apt_ensure_installed "$pkg"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      log_fail "Failed to install $pkg." "$rc"
      return $rc
    fi
  done
  return 0
}

# installer_apt_revert <status_file> <pkg> [<pkg>...]
# For each package, remove it iff its recorded pre-state is "false" (meaning
# we installed it). Packages that were already present are left in place;
# packages already absent are skipped. Errors during apt remove are warned
# but don't halt the loop — uninstall is best-effort.
installer_apt_revert() {
  local status_file="$1"
  shift
  local pkg pre_var pre_state
  for pkg in "$@"; do
    [[ -z $pkg ]] && continue
    pre_var=$(_installer_apt_pre_var "$pkg")
    pre_state=$(status_get "$status_file" "$pre_var")
    if [[ $pre_state == "true" ]]; then
      log_info "Leaving $pkg in place (was installed before)."
      continue
    fi
    if ! apt_is_installed "$pkg"; then
      log_info "$pkg already absent; nothing to remove."
      continue
    fi
    log_info "Removing $pkg (we installed it)."
    apt_remove "$pkg" || log_warn "apt remove $pkg returned non-zero (continuing)."
  done
  return 0
}

_installer_apt_do_install() {
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "$II_TITLE already installed at recorded version. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"
  local STATUS_FILE
  STATUS_FILE=$(status_file_for "$II_ID")

  log_info "Ensuring packages installed: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt-get install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install $II_TITLE. Error Code: $rc."
    return $rc
  fi

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "$II_TITLE installed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed $II_TITLE."
  return 0
}

_installer_apt_do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "$II_TITLE already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] $II_TITLE is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for $II_ID; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  local STATUS_FILE
  STATUS_FILE=$(status_file_for "$II_ID")

  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "$II_TITLE uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled $II_TITLE."
  return 0
}
