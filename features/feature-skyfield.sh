#!/bin/bash

# Module:      SkyfieldAlmanac WeeWX Extension Installer
# Description: Installs the SkyfieldAlmanac extension for WeeWX. Provides
#              high-precision astronomical data (sunrise/set, moon phase,
#              planet positions, etc.) by replacing weewx's built-in pyephem
#              calculations with the Skyfield library.
#
#              Follows the upstream's official install recipe (no git, no
#              source tree on disk):
#                1. Ensure three apt packages (numpy, pandas, python3-skyfield).
#                   Pre-install state is recorded per package so --uninstall
#                   only removes packages we put in place.
#                2. wget the extension ZIP to a temp file.
#                3. Hand the ZIP to WeeWX's own extension CLI — `weectl
#                   extension install` on weewx 5 (Trixie's apt ships 5.x),
#                   `wee_extension --install=` on weewx 4. Auto-detected;
#                   same pattern feature-neowx-material uses.
#
#              --uninstall reverses in opposite order:
#                1. weectl/wee_extension --uninstall (best-effort; weewx may
#                   already be gone if the user pulled it).
#                2. apt-remove the python packages we installed (per-package
#                   pre-state check leaves anything that was already there).
#
#              II_DEPS="weewx weewx-setup" so the scheduler auto-pulls the
#              weewx apt package AND the non-interactive config pass into the
#              queue, ordered before skyfield — the extension installs onto a
#              fully-configured weewx.conf rather than the package default.
#              (The hardened scheduler refuses to start if either dep's
#              installer is missing entirely.)
#
#              v2 notes:
#                - Switched from git clone of Jterrettaz/SkyfieldAlmanac to
#                  ZIP download of roe-dl/weewx-skyfield-almanac. Jterrettaz
#                  was an old fork; roe-dl is the actively-maintained
#                  upstream and matches the WeeWX docs' install recipe.
#                  Bonus: drops the git apt dep AND eliminates the silent
#                  `git clone` hang we hit in the wild.
#                - SKYFIELD_EXTENSION_NAME is the name `weectl extension
#                  list` will report for the registered extension. If
#                  upstream renames it, override the env var.

# === II_MANIFEST_BEGIN ===
II_ID="skyfield"
II_TITLE="SkyfieldAlmanac (WeeWX extension)"
II_CATEGORY="feature"
II_VERSION="3"
II_DEPS="weewx weewx-setup"
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="python3-numpy python3-pandas python3-skyfield"
II_RESTRICT_TO_ROLES="weewx"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/apt.sh
source lib/installer_apt.sh
source lib/verify.sh

SKYFIELD_EXTENSION_URL="${SKYFIELD_EXTENSION_URL:-https://github.com/roe-dl/weewx-skyfield-almanac/archive/refs/heads/master.zip}"
# Must match what `weectl extension list` reports for the registered
# extension — that's the same name `weectl extension uninstall <name>`
# expects. roe-dl ships it as "Skyfield almanac" (space, lowercase 'a').
SKYFIELD_EXTENSION_NAME="${SKYFIELD_EXTENSION_NAME:-Skyfield almanac}"
# Where to park the ~30+ MB of ephemeris / IERS files when the WeeWX DB
# is on zram. The extension's data path is hardcoded to
# WEEWX_ROOT/skyfield (which lands inside /var/lib/weewx, i.e. on the
# zram fs); we redirect it via a symlink so the data lives on SD.
SKYFIELD_OFFLOAD_DIR="${SKYFIELD_OFFLOAD_DIR:-/var/cache/weewx-skyfield}"

# _weewx_ext_tool — echo the WeeWX extension CLI on this box:
# "weectl" (weewx 5), "wee_extension" (weewx 4), or "" if neither is on
# PATH. Same detection pattern feature-neowx-material uses.
_weewx_ext_tool() {
  if command -v weectl >/dev/null 2>&1; then
    echo "weectl"
  elif command -v wee_extension >/dev/null 2>&1; then
    echo "wee_extension"
  else
    echo ""
  fi
}

# _skyfield_db_on_zram — rc=0 if /var/lib/weewx is mounted from a zram
# device (the weewx-database-ram feature is active). Used to decide
# whether to offload the skyfield data dir off the compressed ramdisk.
_skyfield_db_on_zram() {
  local src
  src=$(findmnt -no SOURCE /var/lib/weewx 2>/dev/null)
  [[ $src == /dev/zram* ]]
}

# _skyfield_offload_to_sd — pre-create the offload dir + symlink so the
# extension's first run writes ephemeris files to SD instead of zram.
# Idempotent: skips if /var/lib/weewx/skyfield is already a symlink.
# Migrates any existing data (extension may have already created files
# before this ran). Also runs fstrim so the zram backing-RAM for the
# evicted blocks is released immediately, not lazily on next write.
_skyfield_offload_to_sd() {
  local live="/var/lib/weewx/skyfield"
  local hdd="/var/lib/weewx.hdd/skyfield"
  local cache="$SKYFIELD_OFFLOAD_DIR"

  if [[ -L $live ]]; then
    log_info "Skyfield data dir already symlinked ($live -> $(readlink -f "$live")). Nothing to offload."
    return 0
  fi

  log_info "WeeWX DB is on zram — offloading Skyfield data dir to $cache."
  sudo mkdir -p "$cache"
  if [[ -d $live && ! -L $live ]]; then
    sudo rsync -a "$live/" "$cache/" 2>&1 | tee -a "$FILE_LOG_INSTALLER" >/dev/null
    sudo rm -rf "$live"
  fi
  if [[ -d $hdd && ! -L $hdd ]]; then
    # Merge any SD-mirror copy into the cache too (older snapshot pulls).
    sudo rsync -a "$hdd/" "$cache/" 2>&1 | tee -a "$FILE_LOG_INSTALLER" >/dev/null
    sudo rm -rf "$hdd"
  fi
  sudo chown -R weewx:weewx "$cache"

  sudo ln -s "$cache" "$live"
  # The boot-time rsync from .hdd -> /var/lib/weewx preserves symlinks
  # under rsync -a, so we mirror the symlink on the SD side as well.
  # Only create it if the .hdd path exists (it won't if database-ram
  # isn't yet fully set up).
  if [[ -d /var/lib/weewx.hdd ]]; then
    sudo ln -s "$cache" "$hdd"
  fi

  # Release any blocks we just freed back to system RAM. ext4 was
  # mounted without `discard`, so this is the only path that shrinks
  # zram's compressed footprint without waiting for new writes to
  # naturally overwrite the freed blocks.
  sudo fstrim -v /var/lib/weewx 2>&1 | tee -a "$FILE_LOG_INSTALLER" >/dev/null || true
}

# _skyfield_unsymlink — remove the offload symlinks on uninstall. We
# preserve the cache dir itself so a future re-install can reuse the
# already-downloaded ephemeris files (which are tens of MB and rarely
# change). Only acts if the symlinks point at SKYFIELD_OFFLOAD_DIR --
# never touches symlinks the user put there by hand.
_skyfield_unsymlink() {
  local live="/var/lib/weewx/skyfield"
  local hdd="/var/lib/weewx.hdd/skyfield"
  local cache="$SKYFIELD_OFFLOAD_DIR"

  if [[ -L $live ]] && [[ $(readlink -f "$live" 2>/dev/null) == "$cache" ]]; then
    log_info "Removing offload symlink $live (cache at $cache preserved)."
    sudo rm -f "$live"
  fi
  if [[ -L $hdd ]] && [[ $(readlink -f "$hdd" 2>/dev/null) == "$cache" ]]; then
    log_info "Removing offload symlink $hdd."
    sudo rm -f "$hdd"
  fi
}

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    --verify)    MODE="verify" ;;
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

  # Step 2: pick the extension CLI before we download — fail fast if WeeWX
  # didn't bring one in. (Cheaper than discovering it after a 1-MB wget.)
  local tool
  tool=$(_weewx_ext_tool)
  if [[ -z $tool ]]; then
    log_fail "Neither weectl (weewx 5) nor wee_extension (weewx 4) is on PATH — is WeeWX installed?"
    status_mark_failed "$II_ID" "weewx extension CLI missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not find weectl or wee_extension; is WeeWX installed?"
    return 1
  fi

  # Step 3: download the extension ZIP. --tries=3 + --timeout=30 keeps a
  # flaky connection from silently hanging (the previous git-clone path
  # had no timeout and stuck for hours when the network blipped).
  local zip
  zip=$(mktemp --suffix=.zip) || {
    log_fail "mktemp failed for skyfield zip."
    status_mark_failed "$II_ID" "mktemp failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not create a temp file for the SkyfieldAlmanac extension."
    return 1
  }
  log_info "Downloading SkyfieldAlmanac from $SKYFIELD_EXTENSION_URL."
  if ! wget --tries=3 --timeout=30 -qO "$zip" "$SKYFIELD_EXTENSION_URL"; then
    log_fail "Failed to download $SKYFIELD_EXTENSION_URL."
    rm -f "$zip"
    status_mark_failed "$II_ID" "extension download failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not download the SkyfieldAlmanac extension."
    return 1
  fi

  # Step 4: register the extension. weectl/wee_extension behavior on an
  # already-registered extension varies (some overwrite silently, some
  # error). Soft-fail rather than tank the queue — manual reinstall is
  #   sudo weectl extension uninstall SkyfieldAlmanac --yes
  #   sudo bash installicious.sh
  local install_rc
  if [[ $tool == weectl ]]; then
    log_info "Registering extension with weewx 5: weectl extension install <zip>"
    sudo weectl extension install "$zip" --yes 2>&1 | tee -a "$FILE_LOG_INSTALLER"
    install_rc="${PIPESTATUS[0]}"
  else
    log_info "Registering extension with weewx 4: wee_extension --install=<zip>"
    sudo wee_extension --install="$zip" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
    install_rc="${PIPESTATUS[0]}"
  fi
  rm -f "$zip"
  if [[ $install_rc -ne 0 ]]; then
    log_warn "$tool extension install returned non-zero ($install_rc). The extension may already be registered, or there may be a real error. Verify with: sudo $tool extension list"
    echo -e "[ \e[0;33mWARN\e[0m ] $tool extension install returned non-zero — check '$tool extension list' to confirm SkyfieldAlmanac is registered."
  fi

  # Step 5: if the WeeWX DB is on zram (weewx-database-ram active),
  # offload the ~30+ MB Skyfield data dir to SD via symlink so the
  # extension's first run doesn't burn zram on ephemeris cache. The
  # extension's data path is hardcoded to WEEWX_ROOT/skyfield in
  # user/skyfieldalmanac.py; only the symlink approach works.
  if _skyfield_db_on_zram; then
    _skyfield_offload_to_sd
  else
    log_info "WeeWX DB is not on zram — skipping Skyfield offload (default path is fine)."
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
  local tool
  tool=$(_weewx_ext_tool)
  if [[ $tool == weectl ]]; then
    log_info "Unregistering extension (weewx 5): weectl extension uninstall $SKYFIELD_EXTENSION_NAME"
    sudo weectl extension uninstall "$SKYFIELD_EXTENSION_NAME" --yes \
      || log_warn "weectl extension uninstall returned non-zero (continuing)."
  elif [[ $tool == wee_extension ]]; then
    log_info "Unregistering extension (weewx 4): wee_extension --uninstall $SKYFIELD_EXTENSION_NAME"
    sudo wee_extension --uninstall "$SKYFIELD_EXTENSION_NAME" \
      || log_warn "wee_extension --uninstall returned non-zero (continuing)."
  else
    log_info "Neither weectl nor wee_extension present; skipping extension unregister (weewx likely already removed)."
  fi

  # Step 2: drop offload symlinks if we created any. The cache dir at
  # SKYFIELD_OFFLOAD_DIR is preserved -- a future re-install reuses the
  # already-downloaded ephemeris files (tens of MB, rarely change).
  # Manual cleanup: `sudo rm -rf $SKYFIELD_OFFLOAD_DIR`.
  _skyfield_unsymlink

  # Step 3: revert apt packages we installed. No source tree to remove —
  # the v2 install recipe doesn't keep one on disk.
  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "SkyfieldAlmanac uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled SkyfieldAlmanac."
  return 0
}

do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  # Source of truth is weectl's own bookkeeping — that's the same registry
  # `weectl extension uninstall` consults, so if it lists Skyfield we know
  # the extension is actually wired up. Fallback to the user-module file in
  # case weectl is missing (PATH issues, partially-broken weewx).
  local tool
  tool=$(_weewx_ext_tool)
  if [[ -n $tool ]]; then
    if sudo -n "$tool" extension list 2>/dev/null | grep -iq 'skyfield'; then
      return 0
    fi
    echo "$tool extension list: no skyfield entry"
  fi
  if verify_file_exists /etc/weewx/bin/user/skyfieldalmanac.py 2>/dev/null; then
    return 0
  fi
  echo "skyfield extension not registered (weectl/wee_extension reports nothing) and /etc/weewx/bin/user/skyfieldalmanac.py is missing"
  return 1
}

if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "verify" ]]; then
  do_verify
else
  do_uninstall
fi
exit $?
