#!/bin/bash

# Module:      nginx web server
# Description: Installs nginx and writes /etc/nginx/sites-available/default
#              with the common WEBSERVER_* knobs from the parent
#              feature-webserver. The distro default site is backed up
#              first; --uninstall restores it and apt-removes the package
#              if installicious was the one that put it there.
#
#              Hidden behind II_RESTRICT_TO_ROLES so it only surfaces in
#              the webserver / weewx role flows. Selecting it directly
#              shouldn't happen — the parent feature-webserver's radio
#              sub-menu is the canonical entry point.

# === II_MANIFEST_BEGIN ===
II_ID="nginx"
II_TITLE="nginx"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_APT_PACKAGES="nginx"
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

FILE_CONFIG_WEBSERVER="${PATH_CONFIG:-config}/webserver.config"
[[ -f $FILE_CONFIG_WEBSERVER ]] && source "$FILE_CONFIG_WEBSERVER"
state_apply_menu_overrides
WEBSERVER_DOC_ROOT="${WEBSERVER_DOC_ROOT:-/var/www/html}"
WEBSERVER_PORT="${WEBSERVER_PORT:-80}"
if [[ -z ${WEBSERVER_SERVER_NAME:-} ]]; then
  WEBSERVER_SERVER_NAME=$(hostname -f 2>/dev/null)
  [[ -z $WEBSERVER_SERVER_NAME || $WEBSERVER_SERVER_NAME == "(none)" ]] && WEBSERVER_SERVER_NAME=$(hostname 2>/dev/null)
  [[ -z $WEBSERVER_SERVER_NAME ]] && WEBSERVER_SERVER_NAME="_"
fi

NGINX_DEFAULT_SITE="/etc/nginx/sites-available/default"

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

write_site_config() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<NGINX_EOF
# Managed by installicious feature-nginx.
# Edit WEBSERVER_DOC_ROOT / WEBSERVER_SERVER_NAME / WEBSERVER_PORT via the
# installicious config editor and re-run; this file will be regenerated.

server {
    listen ${WEBSERVER_PORT} default_server;
    listen [::]:${WEBSERVER_PORT} default_server;

    root ${WEBSERVER_DOC_ROOT};
    index index.html index.htm index.nginx-debian.html;

    server_name ${WEBSERVER_SERVER_NAME};

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF
  sudo install -m 0644 "$tmp" "$NGINX_DEFAULT_SITE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"; then
    log_info "nginx already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  log_info "Ensuring apt package: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install nginx. Error Code: $rc."
    return $rc
  fi

  # Snapshot the distro default site once (only on first install — subsequent
  # config-edit re-runs replace OUR version, so we don't want to overwrite the
  # original snapshot).
  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up $NGINX_DEFAULT_SITE before edits."
    backup_create "$II_ID" "$NGINX_DEFAULT_SITE" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  log_info "Writing nginx site config (port=$WEBSERVER_PORT root=$WEBSERVER_DOC_ROOT server_name=$WEBSERVER_SERVER_NAME)."
  if ! write_site_config; then
    status_mark_failed "$II_ID" "site config render failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not render the nginx site config."
    return 1
  fi

  if ! sudo nginx -t 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
    log_warn "nginx -t failed; restoring backup."
    backup_restore_latest "$II_ID" "$NGINX_DEFAULT_SITE" || log_warn "Backup restore failed."
    status_mark_failed "$II_ID" "nginx -t rejected rendered config"
    return 1
  fi

  log_info "Reloading nginx."
  sudo systemctl enable nginx >/dev/null 2>&1 || true
  sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx \
    || log_warn "nginx reload/restart returned non-zero."

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "nginx installed and configured."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed nginx."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "nginx feature already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] nginx is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for nginx; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # Restore the distro default site if we have a snapshot. If the file was
  # never present pre-install, backup_restore_or_remove deletes our managed
  # version cleanly.
  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $NGINX_DEFAULT_SITE from snapshot."
    backup_restore_or_remove "$II_ID" "$NGINX_DEFAULT_SITE" \
      || log_warn "Site config restore returned non-zero."
  fi

  # apt-revert: removes nginx iff installicious installed it.
  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "nginx uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled nginx."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
