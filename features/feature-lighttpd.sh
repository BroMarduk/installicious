#!/bin/bash

# Module:      lighttpd web server
# Description: Installs lighttpd and writes /etc/lighttpd/lighttpd.conf
#              with the common WEBSERVER_* knobs. Distro default config
#              is snapshotted before edits; --uninstall restores it and
#              apt-removes the package if installicious installed it.
#
#              Hidden behind II_RESTRICT_TO_ROLES so it only surfaces in
#              the webserver / weewx role flows via feature-webserver's
#              radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="lighttpd"
II_TITLE="lighttpd"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_APT_PACKAGES="lighttpd"
II_RESTRICT_TO_ROLES="webserver weewx"
II_OPTIONAL_GROUP="webserver-under-construction webserver-ssl"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh
source lib/apt.sh
source lib/installer_apt.sh
source lib/verify.sh

FILE_CONFIG_WEBSERVER="${PATH_CONFIG:-config}/webserver.config"
[[ -f $FILE_CONFIG_WEBSERVER ]] && source "$FILE_CONFIG_WEBSERVER"
state_apply_menu_overrides
WEBSERVER_DOC_ROOT="${WEBSERVER_DOC_ROOT:-/var/www/html}"
WEBSERVER_PORT="${WEBSERVER_PORT:-80}"
if [[ -z ${WEBSERVER_SERVER_NAME:-} ]]; then
  WEBSERVER_SERVER_NAME=$(hostname -f 2>/dev/null)
  [[ -z $WEBSERVER_SERVER_NAME || $WEBSERVER_SERVER_NAME == "(none)" ]] && WEBSERVER_SERVER_NAME=$(hostname 2>/dev/null)
  [[ -z $WEBSERVER_SERVER_NAME ]] && WEBSERVER_SERVER_NAME="localhost"
fi

LIGHTTPD_CONF="/etc/lighttpd/lighttpd.conf"

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

write_lighttpd_conf() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<LIGHTTPD_EOF
# Managed by installicious feature-lighttpd.
# Edit WEBSERVER_DOC_ROOT / WEBSERVER_SERVER_NAME / WEBSERVER_PORT via
# the installicious config editor and re-run; this file is regenerated.

server.modules = (
    "mod_indexfile",
    "mod_access",
    "mod_alias",
    "mod_redirect",
)

server.document-root        = "${WEBSERVER_DOC_ROOT}"
server.upload-dirs          = ( "/var/cache/lighttpd/uploads" )
server.errorlog             = "/var/log/lighttpd/error.log"
server.pid-file             = "/run/lighttpd.pid"
server.username             = "www-data"
server.groupname            = "www-data"
server.port                 = ${WEBSERVER_PORT}
server.name                 = "${WEBSERVER_SERVER_NAME}"

index-file.names            = ( "index.php", "index.html" )
url.access-deny             = ( "~", ".inc" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )

include_shell "/usr/share/lighttpd/create-mime.conf.pl"
include "/etc/lighttpd/conf-enabled/*.conf"
LIGHTTPD_EOF
  sudo install -m 0644 "$tmp" "$LIGHTTPD_CONF" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"; then
    log_info "lighttpd already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  log_info "Ensuring apt package: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install lighttpd. Error Code: $rc."
    return $rc
  fi

  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up $LIGHTTPD_CONF before edits."
    backup_create "$II_ID" "$LIGHTTPD_CONF" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  log_info "Writing lighttpd config (port=$WEBSERVER_PORT root=$WEBSERVER_DOC_ROOT server_name=$WEBSERVER_SERVER_NAME)."
  if ! write_lighttpd_conf; then
    status_mark_failed "$II_ID" "lighttpd config render failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not render the lighttpd config."
    return 1
  fi

  if ! sudo lighttpd -t -f "$LIGHTTPD_CONF" 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
    log_warn "lighttpd config test failed; restoring backup."
    backup_restore_latest "$II_ID" "$LIGHTTPD_CONF" || log_warn "Backup restore failed."
    status_mark_failed "$II_ID" "lighttpd -t rejected rendered config"
    return 1
  fi

  log_info "Restarting lighttpd."
  sudo systemctl enable lighttpd >/dev/null 2>&1 || true
  sudo systemctl restart lighttpd 2>/dev/null \
    || log_warn "lighttpd restart returned non-zero."

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "lighttpd installed and configured."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed lighttpd."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "lighttpd feature already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] lighttpd is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for lighttpd; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $LIGHTTPD_CONF from snapshot."
    backup_restore_or_remove "$II_ID" "$LIGHTTPD_CONF" \
      || log_warn "lighttpd config restore returned non-zero."
  fi

  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "lighttpd uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled lighttpd."
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
