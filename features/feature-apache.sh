#!/bin/bash

# Module:      Apache web server
# Description: Installs apache2 and writes a managed default VirtualHost
#              + ports config from the common WEBSERVER_* knobs. Distro
#              defaults are snapshotted before edits; --uninstall
#              restores them and apt-removes the package if installicious
#              installed it.
#
#              Hidden behind II_RESTRICT_TO_ROLES so it only surfaces in
#              the webserver / weewx role flows via feature-webserver's
#              radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="apache"
II_TITLE="Apache (apache2)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_APT_PACKAGES="apache2"
II_RESTRICT_TO_ROLES="webserver weewx"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh
source lib/apt.sh
source lib/installer_apt.sh

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

APACHE_PORTS_CONF="/etc/apache2/ports.conf"
APACHE_DEFAULT_VHOST="/etc/apache2/sites-available/000-default.conf"

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

write_ports_conf() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<APACHE_EOF
# Managed by installicious feature-apache.
# Edit WEBSERVER_PORT via the installicious config editor and re-run.
Listen ${WEBSERVER_PORT}

<IfModule ssl_module>
    Listen 443
</IfModule>

<IfModule mod_gnutls.c>
    Listen 443
</IfModule>
APACHE_EOF
  sudo install -m 0644 "$tmp" "$APACHE_PORTS_CONF" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

write_default_vhost() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<APACHE_EOF
# Managed by installicious feature-apache.
# Edit WEBSERVER_DOC_ROOT / WEBSERVER_SERVER_NAME / WEBSERVER_PORT via
# the installicious config editor and re-run.

<VirtualHost *:${WEBSERVER_PORT}>
    ServerName ${WEBSERVER_SERVER_NAME}
    DocumentRoot ${WEBSERVER_DOC_ROOT}

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHE_EOF
  sudo install -m 0644 "$tmp" "$APACHE_DEFAULT_VHOST" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"; then
    log_info "Apache already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  log_info "Ensuring apt package: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Apache. Error Code: $rc."
    return $rc
  fi

  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up apache config files before edits."
    backup_create "$II_ID" "$APACHE_PORTS_CONF" "$APACHE_DEFAULT_VHOST" >/dev/null \
      || log_warn "backup_create failed; continuing."
  fi

  log_info "Writing apache config (port=$WEBSERVER_PORT root=$WEBSERVER_DOC_ROOT server_name=$WEBSERVER_SERVER_NAME)."
  if ! write_ports_conf || ! write_default_vhost; then
    status_mark_failed "$II_ID" "apache config render failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not render the Apache config."
    return 1
  fi

  if ! sudo apache2ctl configtest 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
    log_warn "apache2ctl configtest failed; restoring backups."
    backup_restore_latest "$II_ID" "$APACHE_PORTS_CONF" "$APACHE_DEFAULT_VHOST" \
      || log_warn "Backup restore failed."
    status_mark_failed "$II_ID" "apache2ctl configtest rejected rendered config"
    return 1
  fi

  log_info "Reloading apache2."
  sudo systemctl enable apache2 >/dev/null 2>&1 || true
  sudo systemctl reload apache2 2>/dev/null || sudo systemctl restart apache2 \
    || log_warn "apache2 reload/restart returned non-zero."

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "Apache installed and configured."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed Apache."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Apache feature already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Apache is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for apache; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring apache config files from snapshot."
    backup_restore_or_remove "$II_ID" "$APACHE_PORTS_CONF" "$APACHE_DEFAULT_VHOST" \
      || log_warn "Apache config restore returned non-zero."
  fi

  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "Apache uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled Apache."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
