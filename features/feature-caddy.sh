#!/bin/bash

# Module:      Caddy web server
# Description: Installs caddy and writes /etc/caddy/Caddyfile from the
#              common WEBSERVER_* knobs. Distro default Caddyfile is
#              snapshotted before edits; --uninstall restores it and
#              apt-removes the package if installicious installed it.
#
#              Caddy ships with auto-HTTPS on; for v1 we keep things
#              simple and bind plain HTTP on the configured port. SSL
#              setup (Let's Encrypt or local CA) is a follow-up feature.
#
#              Hidden behind II_RESTRICT_TO_ROLES so it only surfaces in
#              the webserver / weewx role flows via feature-webserver's
#              radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="caddy"
II_TITLE="Caddy"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_APT_PACKAGES="caddy"
II_RESTRICT_TO_ROLES="webserver weewx"
# Caddy has built-in auto-HTTPS, but the user may still want to control
# the HTTP-side policy (redirect-all / redirect-name / deny-http). When
# webserver-ssl is selected for Caddy, certbot is skipped — instead we
# write a Caddyfile that uses Caddy's built-in ACME client plus the
# user's chosen HTTP policy. WEBSERVER_SSL_METHOD is informational only
# for Caddy (the vanilla apt build doesn't include DNS plugins).
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
  [[ -z $WEBSERVER_SERVER_NAME ]] && WEBSERVER_SERVER_NAME="localhost"
fi

CADDYFILE="/etc/caddy/Caddyfile"

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

write_caddyfile() {
  local tmp
  tmp=$(mktemp) || return 1
  # If the user kept the default port 80, use ":80" so Caddy binds the
  # well-known port without the auto-HTTPS pipeline. For non-80, use
  # explicit hostname:port so the rule still matches.
  local site
  if [[ "$WEBSERVER_PORT" == "80" ]]; then
    site="http://${WEBSERVER_SERVER_NAME}, :80"
  else
    site="http://${WEBSERVER_SERVER_NAME}:${WEBSERVER_PORT}"
  fi
  cat > "$tmp" <<CADDY_EOF
# Managed by installicious feature-caddy.
# Edit WEBSERVER_DOC_ROOT / WEBSERVER_SERVER_NAME / WEBSERVER_PORT via
# the installicious config editor and re-run; this file is regenerated.

${site} {
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}
CADDY_EOF
  sudo install -m 0644 "$tmp" "$CADDYFILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"; then
    log_info "Caddy already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  log_info "Ensuring apt package: $II_APT_PACKAGES"
  # shellcheck disable=SC2086
  installer_apt_record_install "$STATUS_FILE" $II_APT_PACKAGES
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Caddy. Error Code: $rc."
    return $rc
  fi

  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up $CADDYFILE before edits."
    backup_create "$II_ID" "$CADDYFILE" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  log_info "Writing Caddyfile (port=$WEBSERVER_PORT root=$WEBSERVER_DOC_ROOT server_name=$WEBSERVER_SERVER_NAME)."
  if ! write_caddyfile; then
    status_mark_failed "$II_ID" "Caddyfile render failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not render the Caddyfile."
    return 1
  fi

  if ! sudo caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
    log_warn "caddy validate failed; restoring backup."
    backup_restore_latest "$II_ID" "$CADDYFILE" || log_warn "Backup restore failed."
    status_mark_failed "$II_ID" "caddy validate rejected rendered Caddyfile"
    return 1
  fi

  log_info "Reloading caddy."
  sudo systemctl enable caddy >/dev/null 2>&1 || true
  sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy \
    || log_warn "caddy reload/restart returned non-zero."

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "Caddy installed and configured."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed Caddy."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "Caddy feature already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] Caddy is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for caddy; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $CADDYFILE from snapshot."
    backup_restore_or_remove "$II_ID" "$CADDYFILE" \
      || log_warn "Caddyfile restore returned non-zero."
  fi

  # shellcheck disable=SC2086
  installer_apt_revert "$STATUS_FILE" $II_APT_PACKAGES

  status_mark_uninstalled "$II_ID"
  log_ok "Caddy uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled Caddy."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
