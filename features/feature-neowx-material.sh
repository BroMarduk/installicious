#!/bin/bash

# Module:      NeoWX Material WeeWX skin
# Description: Installs the NeoWX Material skin — seehase's actively-
#              maintained fork: https://github.com/seehase/neowx-material
#              — and wires up everything its README calls out:
#
#                1. INSTALL — downloads the extension archive
#                   (NEOWX_EXTENSION_URL) and installs it with WeeWX's
#                   own extension CLI: `weectl extension install` on
#                   weewx 5, `wee_extension --install` on weewx 4
#                   (auto-detected). That drops the skin into
#                   /etc/weewx/skins/neowx-material/ and registers a
#                   [StdReport][[neowx-material]] section in weewx.conf.
#
#                2. LOCALIZATION (weewx.conf) — merges lang / HTML_ROOT /
#                   enable into [StdReport][[neowx-material]] so the skin
#                   renders in NEOWX_LANG and writes to NEOWX_HTML_ROOT.
#
#                3. TIME & DATE — when NEOWX_LOCALE is set, writes a
#                   systemd drop-in (/etc/systemd/system/weewx.service.d/
#                   neowx-locale.conf) with Environment="LANG=<locale>"
#                   so WeeWX renders dates/times in that locale. This is
#                   the clean equivalent of the README's "edit
#                   weewx.service" step — a drop-in survives package
#                   updates. The locale must already be generated
#                   (feature-locale does that, or dpkg-reconfigure
#                   locales); we warn but don't fail if it's missing.
#
#                4. SKIN CONFIG — deep-merges the user's
#                   overrides/neowx-material-skin.conf onto the skin's
#                   /etc/weewx/skins/neowx-material/skin.conf via
#                   resources/weewx-merge-overrides.py (same configobj
#                   helper feature-weewx-setup uses). Empty override
#                   file = no-op.
#
#              II_DEPS="weewx weewx-setup" — the apt package + the
#              non-interactive station config pass run first, so the
#              skin installs onto a configured WeeWX.
#
#              Symmetric --uninstall: uninstalls the extension via the
#              WeeWX CLI (which removes the skin dir + its weewx.conf
#              section), removes the locale drop-in, restores weewx.conf
#              from the pre-install snapshot, restarts WeeWX.

# === II_MANIFEST_BEGIN ===
II_ID="neowx-material"
II_TITLE="NeoWX Material WeeWX skin"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="weewx weewx-setup"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_EDITABLE_CONFIG="NEOWX_LANG NEOWX_LOCALE NEOWX_HTML_ROOT"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh

FILE_CONFIG_NEOWX="${PATH_CONFIG:-config}/neowx-material.config"
[[ -f $FILE_CONFIG_NEOWX ]] && source "$FILE_CONFIG_NEOWX"
state_apply_menu_overrides
NEOWX_LANG="${NEOWX_LANG:-en}"
NEOWX_LOCALE="${NEOWX_LOCALE:-}"
NEOWX_HTML_ROOT="${NEOWX_HTML_ROOT:-/var/www/html/weewx}"
NEOWX_EXTENSION_URL="${NEOWX_EXTENSION_URL:-https://github.com/seehase/neowx-material/archive/refs/heads/master.zip}"

WEEWX_CONF="/etc/weewx/weewx.conf"
SKIN_DIR="/etc/weewx/skins/neowx-material"
SKIN_CONF="${SKIN_DIR}/skin.conf"
SKIN_REPORT_NAME="neowx-material"          # [StdReport][[<this>]] section name
LOCALE_DROPIN_DIR="/etc/systemd/system/weewx.service.d"
LOCALE_DROPIN="${LOCALE_DROPIN_DIR}/neowx-locale.conf"
# overrides/neowx-material-skin.conf is the git-tracked default template.
# A sibling neowx-material-skin.override — if present — is the user's
# personal copy (gitignored via the *.override rule) and takes precedence.
OVERRIDE_FILE="${PATH_OVERRIDES:-overrides}/neowx-material-skin.conf"
_personal_override="${OVERRIDE_FILE%.conf}.override"
[[ -f "$_personal_override" ]] && OVERRIDE_FILE="$_personal_override"
MERGE_HELPER="${PATH_RESOURCES:-resources}/weewx-merge-overrides.py"

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

# _weewx_ext_tool — echo the WeeWX extension CLI available on this box:
# "weectl" (weewx 5), "wee_extension" (weewx 4), or "" if neither.
_weewx_ext_tool() {
  if command -v weectl >/dev/null 2>&1; then
    echo "weectl"
  elif command -v wee_extension >/dev/null 2>&1; then
    echo "wee_extension"
  else
    echo ""
  fi
}

# _neowx_installed_ext_name <tool> — echo the registered extension name
# for the NeoWX skin by scanning the CLI's extension list (the name the
# extension's install.py registers can differ from the skin dir name).
# Falls back to "neowx-material" if the scan turns up nothing.
_neowx_installed_ext_name() {
  local tool="$1" listing
  if [[ $tool == weectl ]]; then
    listing=$(weectl extension list 2>/dev/null)
  elif [[ $tool == wee_extension ]]; then
    listing=$(wee_extension --list 2>/dev/null)
  fi
  local name
  name=$(echo "$listing" | grep -i 'neowx' | awk '{print $1}' | head -1)
  echo "${name:-neowx-material}"
}

# merge_weewx_conf_localization — generate a small ConfigObj snippet that
# sets lang / HTML_ROOT / enable under [StdReport][[neowx-material]] and
# deep-merge it onto weewx.conf. weectl extension install already creates
# that section; this just guarantees our three keys are what we want.
merge_weewx_conf_localization() {
  local snippet
  snippet=$(mktemp) || return 1
  # Indentation matters in ConfigObj — [[...]] is one level under [...].
  cat > "$snippet" <<EOF
[StdReport]
    [[${SKIN_REPORT_NAME}]]
        skin = neowx-material
        enable = true
        lang = ${NEOWX_LANG}
        HTML_ROOT = ${NEOWX_HTML_ROOT}
EOF
  log_info "Merging [StdReport][[${SKIN_REPORT_NAME}]] lang=${NEOWX_LANG} HTML_ROOT=${NEOWX_HTML_ROOT} into $WEEWX_CONF."
  sudo python3 "$MERGE_HELPER" "$WEEWX_CONF" "$snippet" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  local rc="${PIPESTATUS[0]}"
  rm -f "$snippet"
  return "$rc"
}

# write_locale_dropin — write/refresh the weewx.service LANG drop-in when
# NEOWX_LOCALE is set; remove it when NEOWX_LOCALE is blank. Warns (does
# not fail) if the requested locale isn't generated on the system yet.
write_locale_dropin() {
  if [[ -z $NEOWX_LOCALE ]]; then
    if [[ -f $LOCALE_DROPIN ]]; then
      log_info "NEOWX_LOCALE is blank — removing the stale $LOCALE_DROPIN drop-in."
      sudo rm -f "$LOCALE_DROPIN"
    fi
    return 0
  fi
  if ! locale -a 2>/dev/null | grep -qixF "${NEOWX_LOCALE/.UTF-8/.utf8}" \
     && ! locale -a 2>/dev/null | grep -qixF "$NEOWX_LOCALE"; then
    log_warn "Locale '$NEOWX_LOCALE' isn't generated on this system — WeeWX will fall back to C until it is. Install it via feature-locale or 'sudo dpkg-reconfigure locales'."
  fi
  log_info "Writing $LOCALE_DROPIN with LANG=$NEOWX_LOCALE."
  sudo mkdir -p "$LOCALE_DROPIN_DIR" || return 1
  sudo tee "$LOCALE_DROPIN" >/dev/null <<EOF
# Generated by installicious feature-neowx-material.
# Makes WeeWX render dates/times under NEOWX_LOCALE — the clean
# equivalent of the NeoWX README's "edit weewx.service" step.
[Service]
Environment="LANG=${NEOWX_LOCALE}"
EOF
}

# apply_skin_overrides — deep-merge overrides/neowx-material-skin.conf onto
# the skin's skin.conf. Missing / all-comments override file is a no-op.
apply_skin_overrides() {
  if [[ ! -f $OVERRIDE_FILE ]]; then
    log_info "No skin override file at $OVERRIDE_FILE; skipping the merge pass."
    return 0
  fi
  if [[ ! -f $SKIN_CONF ]]; then
    log_warn "Skin config not found at $SKIN_CONF — the extension install may have used a different layout. Skipping the override merge."
    return 0
  fi
  if [[ ! -f $MERGE_HELPER ]]; then
    log_fail "Merge helper missing at $MERGE_HELPER."
    return 1
  fi
  log_info "Merging $OVERRIDE_FILE onto $SKIN_CONF."
  sudo python3 "$MERGE_HELPER" "$SKIN_CONF" "$OVERRIDE_FILE" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  return "${PIPESTATUS[0]}"
}

do_install() {
  # Hash the neowx-material.config AND the resolved skin override file,
  # so editing overrides/neowx-material-skin.override re-triggers the
  # skin merge instead of being silently skipped.
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_NEOWX" "$OVERRIDE_FILE"; then
    log_info "neowx-material already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  if [[ ! -f $WEEWX_CONF ]]; then
    log_fail "$WEEWX_CONF not found — install the weewx package first."
    status_mark_failed "$II_ID" "weewx.conf missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] neowx-material: $WEEWX_CONF is missing (is WeeWX installed?)."
    return 1
  fi

  local tool
  tool=$(_weewx_ext_tool)
  if [[ -z $tool ]]; then
    log_fail "Neither weectl (weewx 5) nor wee_extension (weewx 4) is on PATH."
    status_mark_failed "$II_ID" "no weewx extension CLI"
    echo -e "[ \e[0;31mFAIL\e[0m ] neowx-material: can't find weectl or wee_extension."
    return 1
  fi

  # Stop weewx so the extension install + config edits don't race a
  # running instance. Remember whether to restart it.
  local weewx_was_active=false
  if systemctl is-active --quiet weewx 2>/dev/null; then
    weewx_was_active=true
    log_info "Stopping weewx for the skin install."
    sudo systemctl stop weewx || log_warn "systemctl stop weewx returned non-zero."
  fi

  # Snapshot weewx.conf before the extension install + our merge. The
  # skin dir itself isn't snapshotted — `weectl extension uninstall`
  # removes it wholesale on --uninstall.
  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up $WEEWX_CONF."
    backup_create "$II_ID" "$WEEWX_CONF" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  # 1. Download the extension archive, then install from the local file
  # (clearer failure mode than handing the CLI a URL and hoping).
  local zip
  zip=$(mktemp --suffix=.zip) || { status_mark_failed "$II_ID" "mktemp failed"; return 1; }
  log_info "Downloading the NeoWX Material extension from $NEOWX_EXTENSION_URL."
  if ! wget -qO "$zip" "$NEOWX_EXTENSION_URL"; then
    log_fail "Failed to download $NEOWX_EXTENSION_URL."
    rm -f "$zip"
    status_mark_failed "$II_ID" "extension download failed"
    return 1
  fi

  log_info "Installing the extension via $tool."
  local install_rc
  if [[ $tool == weectl ]]; then
    sudo weectl extension install "$zip" --yes 2>&1 | tee -a "$FILE_LOG_INSTALLER"
    install_rc="${PIPESTATUS[0]}"
  else
    sudo wee_extension --install="$zip" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
    install_rc="${PIPESTATUS[0]}"
  fi
  rm -f "$zip"
  if [[ $install_rc -ne 0 ]]; then
    log_fail "Extension install failed (rc=$install_rc)."
    backup_restore_or_remove "$II_ID" "$WEEWX_CONF" || log_warn "restore returned non-zero."
    status_mark_failed "$II_ID" "extension install failed"
    return 1
  fi

  # 2. Localization in weewx.conf.
  if ! merge_weewx_conf_localization; then
    log_fail "weewx.conf localization merge failed."
    backup_restore_or_remove "$II_ID" "$WEEWX_CONF" || log_warn "restore returned non-zero."
    status_mark_failed "$II_ID" "weewx.conf merge failed"
    return 1
  fi

  # 3. Time & Date — locale drop-in for the weewx service.
  if ! write_locale_dropin; then
    log_fail "Failed to write the locale drop-in."
    status_mark_failed "$II_ID" "locale drop-in failed"
    return 1
  fi

  # 4. Skin config — user's overrides deep-merged onto skin.conf.
  if ! apply_skin_overrides; then
    log_fail "skin.conf override merge failed."
    status_mark_failed "$II_ID" "skin override merge failed"
    return 1
  fi

  log_info "Reloading systemd (picked up the weewx.service drop-in)."
  sudo systemctl daemon-reload || log_warn "systemctl daemon-reload returned non-zero."

  if [[ $weewx_was_active == "true" ]]; then
    log_info "Restarting weewx."
    sudo systemctl start weewx || log_warn "weewx restart returned non-zero."
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_NEOWX" "$OVERRIDE_FILE"
  log_ok "neowx-material installed."
  echo -e "[  \e[0;32mOK\e[0m  ] NeoWX Material skin installed (lang=${NEOWX_LANG}, HTML_ROOT=${NEOWX_HTML_ROOT})."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "neowx-material already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] neowx-material is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record for neowx-material; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  local weewx_was_active=false
  if systemctl is-active --quiet weewx 2>/dev/null; then
    weewx_was_active=true
    sudo systemctl stop weewx 2>/dev/null || true
  fi

  # Uninstall the extension via the WeeWX CLI — that removes the skin dir
  # and the [StdReport][[neowx-material]] section it added.
  local tool
  tool=$(_weewx_ext_tool)
  if [[ -n $tool ]]; then
    local ext_name
    ext_name=$(_neowx_installed_ext_name "$tool")
    log_info "Uninstalling the extension '$ext_name' via $tool."
    if [[ $tool == weectl ]]; then
      sudo weectl extension uninstall "$ext_name" --yes 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
        || log_warn "weectl extension uninstall returned non-zero."
    else
      sudo wee_extension --uninstall="$ext_name" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
        || log_warn "wee_extension --uninstall returned non-zero."
    fi
  else
    log_warn "No weewx extension CLI found — leaving the skin dir in place; remove $SKIN_DIR by hand if needed."
  fi

  # Remove the locale drop-in.
  if [[ -f $LOCALE_DROPIN ]]; then
    log_info "Removing $LOCALE_DROPIN."
    sudo rm -f "$LOCALE_DROPIN"
    sudo rmdir "$LOCALE_DROPIN_DIR" 2>/dev/null || true
  fi

  # Restore weewx.conf from the pre-install snapshot — belt-and-suspenders
  # on top of the CLI uninstall, so any merge keys the CLI didn't know to
  # strip are reverted too.
  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $WEEWX_CONF from snapshot."
    backup_restore_or_remove "$II_ID" "$WEEWX_CONF" || log_warn "weewx.conf restore returned non-zero."
  fi

  sudo systemctl daemon-reload || log_warn "systemctl daemon-reload returned non-zero."

  if [[ $weewx_was_active == "true" ]]; then
    sudo systemctl start weewx || log_warn "weewx restart returned non-zero."
  fi

  status_mark_uninstalled "$II_ID"
  log_ok "neowx-material uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] neowx-material uninstalled (extension removed, weewx.conf restored)."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
