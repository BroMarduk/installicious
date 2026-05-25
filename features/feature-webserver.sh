#!/bin/bash

# Module:      Web Server (parent grouping feature)
# Description: Pure grouping shell. Selecting "webserver" triggers a
#              single-select sub-menu (II_OPTIONAL_GROUP_MODE="exclusive")
#              where the user picks ONE of nginx / apache / lighttpd /
#              caddy. The chosen backend reads the common WEBSERVER_*
#              config keys this parent declares and writes its own
#              native config file accordingly.
#
#              Visible in every role and in the Custom flow — picking
#              this feature anywhere fires the radio so only one HTTP
#              backend can be installed at a time. The four backends
#              themselves stay restricted (II_RESTRICT_TO_ROLES on
#              each) since they're hidden children and shouldn't
#              surface as standalone rows in any picker.
#
#              The body is intentionally a no-op apart from status
#              bookkeeping — all real install work happens in the
#              chosen child feature. Bump II_VERSION if the picker
#              semantics or shared keys change so the parent re-runs.
#
#              Why a parent at all (vs. a role-level radio)? II_DEPS
#              resolution and the menu sub-menu trigger are both
#              feature-level today, so a parent feature is the
#              minimal-blast-radius hook for a single radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="webserver"
II_TITLE="Web Server"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_EDITABLE_CONFIG="WEBSERVER_DOC_ROOT WEBSERVER_SERVER_NAME WEBSERVER_PORT"
II_OPTIONAL_GROUP="nginx apache lighttpd caddy"
II_OPTIONAL_GROUP_MODE="exclusive"
II_RESTRICT_TO_ROLES=""
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/verify.sh

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

do_verify() { verify_generic "$II_ID"; }
if [[ $MODE == "verify" ]]; then do_verify; exit $?; fi

if [[ $MODE == "install" ]]; then
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "Web Server (parent) already recorded at version $II_VERSION. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"
  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "Web Server parent recorded; backend (apache/nginx/lighttpd/caddy) handles install."
  exit 0
fi

# --uninstall: nothing to revert here; the chosen backend's own
# --uninstall reverts apt + config. Mark uninstalled so re-running
# install isn't blocked by a stale 'completed' record.
status_mark_uninstalled "$II_ID"
log_ok "Web Server parent record cleared."
exit 0
