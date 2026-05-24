#!/bin/bash

# Module:      Web Server - Under Construction landing page
# Description: Drops one of the resources/html-index-*.html templates in
#              place as the chosen backend's index.html so visitors hit a
#              polite "we're working on it" page until the real site is
#              deployed. The user picks which template via the
#              WEBSERVER_UC_TEMPLATE config key — see the choices file
#              for the radio (auto-discovered from resources/).
#
#              Hidden child of nginx / apache / lighttpd / caddy via
#              their II_OPTIONAL_GROUP, so it only surfaces in the
#              sub-menu that fires AFTER the radio backend pick. Backend-
#              agnostic — just writes WEBSERVER_DOC_ROOT/index.html.
#
#              The HTML templates live under resources/ so swapping in a
#              different design is just dropping a new
#              html-index-<slug>.html file there; no shell changes
#              needed. Symmetric uninstall restores whatever index.html
#              the distro shipped (snapshotted via lib/backup the first
#              time we touch the file).

# === II_MANIFEST_BEGIN ===
II_ID="webserver-under-construction"
II_TITLE="Under Construction landing page"
II_CATEGORY="feature"
II_VERSION="2"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_CONFLICTS_WITH="weewx-site-ram"
II_EDITABLE_CONFIG="WEBSERVER_UC_TEMPLATE"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh
source lib/verify.sh

FILE_CONFIG_WEBSERVER="${PATH_CONFIG:-config}/webserver.config"
[[ -f $FILE_CONFIG_WEBSERVER ]] && source "$FILE_CONFIG_WEBSERVER"
state_apply_menu_overrides
WEBSERVER_DOC_ROOT="${WEBSERVER_DOC_ROOT:-/var/www/html}"
WEBSERVER_UC_TEMPLATE="${WEBSERVER_UC_TEMPLATE:-midnight-editor}"

UC_SRC="${PATH_RESOURCES:-resources}/html-index-${WEBSERVER_UC_TEMPLATE}.html"
UC_DEST="${WEBSERVER_DOC_ROOT}/index.html"

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
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"; then
    log_info "Under-Construction page already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  if [[ ! -f $UC_SRC ]]; then
    log_fail "Under-Construction template missing at $UC_SRC."
    status_mark_failed "$II_ID" "template missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not find $UC_SRC."
    return 1
  fi

  # Ensure the document root exists. The backend feature should have
  # created/populated it by now, but apt-default behavior varies, so be
  # defensive about it.
  if [[ ! -d $WEBSERVER_DOC_ROOT ]]; then
    log_info "Creating $WEBSERVER_DOC_ROOT (didn't exist)."
    sudo mkdir -p "$WEBSERVER_DOC_ROOT" || {
      status_mark_failed "$II_ID" "could not create doc root"
      return 1
    }
  fi

  # Snapshot the existing index.html (if any) before overwriting. Only
  # take the snapshot ONCE, so subsequent config-edit re-runs don't
  # overwrite the original capture with our managed copy.
  if [[ -z $(backup_latest "$II_ID") ]] && [[ -f $UC_DEST ]]; then
    log_info "Backing up existing $UC_DEST."
    backup_create "$II_ID" "$UC_DEST" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  log_info "Installing Under-Construction page at $UC_DEST."
  sudo install -m 0644 "$UC_SRC" "$UC_DEST" || {
    status_mark_failed "$II_ID" "install failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not write $UC_DEST."
    return 1
  }

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "Under-Construction landing page installed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed the Under-Construction page."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Under-Construction page already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Under-Construction page is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for webserver-under-construction; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $UC_DEST from snapshot."
    backup_restore_or_remove "$II_ID" "$UC_DEST" \
      || log_warn "index.html restore returned non-zero."
  elif [[ -f $UC_DEST ]]; then
    # No snapshot taken — the file didn't exist pre-install. Remove our
    # copy so the user gets a clean state back.
    log_info "Removing $UC_DEST (no prior version to restore)."
    sudo rm -f "$UC_DEST"
  fi

  status_mark_uninstalled "$II_ID"
  log_ok "Under-Construction page uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled the Under-Construction page."
  return 0
}

do_verify() { verify_generic "$II_ID"; }

if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "verify" ]]; then
  do_verify
else
  do_uninstall
fi
exit $?
