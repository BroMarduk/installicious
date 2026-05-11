#!/bin/bash

# Module:      Caddy web server
# Description: Installs caddy and writes /etc/caddy/Caddyfile based on
#              the user's chosen CADDY_HTTP_POLICY (mirrors the
#              WEBSERVER_SSL_HTTP_POLICY values used by nginx / apache /
#              lighttpd, but plugs into Caddy's own built-in ACME
#              client instead of certbot — no python3-certbot-* deps,
#              no DNS plugin gymnastics, just Caddy doing its thing).
#
#              CADDY_HTTP_POLICY values:
#                "redirect-all"  (default) every HTTP request -> HTTPS
#                "redirect-name" only Host==WEBSERVER_SERVER_NAME
#                                redirects; other Hosts keep plain
#                                HTTP (Caddy's default behavior)
#                "deny-http"     :80 closes for everything except the
#                                ACME challenge path
#
#              Caddy auto-issues a Let's Encrypt cert when the
#              configured site name is a real public domain reachable
#              from the internet. For non-public names (e.g. the Pi's
#              hostname.local), Caddy falls back to its local CA so
#              the site still serves HTTPS — convenient for LAN
#              testing without a real domain.
#
#              CADDY_ACME_EMAIL is the registration address Caddy
#              gives Let's Encrypt for renewal reminders. Required.
#
#              Distro default Caddyfile is snapshotted before edits;
#              --uninstall restores it and apt-removes the package if
#              installicious installed it. Hidden behind
#              II_RESTRICT_TO_ROLES so it only surfaces in the
#              webserver / weewx role flows via feature-webserver's
#              radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="caddy"
II_TITLE="Caddy"
II_CATEGORY="feature"
II_VERSION="2"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_APT_PACKAGES="caddy"
II_RESTRICT_TO_ROLES="webserver weewx"
II_OPTIONAL_GROUP="webserver-under-construction"
# Caddy has its own built-in ACME client and HTTP policy controls, so
# webserver-ssl is deliberately NOT in this group. CADDY_HTTP_POLICY
# below (an II_EDITABLE_CONFIG key declared here, not on webserver-ssl)
# mirrors the WEBSERVER_SSL_HTTP_POLICY values for parity with the
# other backends but plugs into Caddy's own auto-HTTPS pipeline.
II_EDITABLE_CONFIG="CADDY_HTTP_POLICY CADDY_ACME_EMAIL"
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
CADDY_HTTP_POLICY="${CADDY_HTTP_POLICY:-redirect-all}"
CADDY_ACME_EMAIL="${CADDY_ACME_EMAIL:-}"
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
  case "$CADDY_HTTP_POLICY" in
    redirect-name)
      cat > "$tmp" <<CADDY_EOF
# Managed by installicious feature-caddy. Edit CADDY_HTTP_POLICY /
# WEBSERVER_SERVER_NAME / CADDY_ACME_EMAIL via the config editor and
# re-run; this file is regenerated.
#
# Policy: redirect-name (Caddy default — only the named site redirects).

{
    email ${CADDY_ACME_EMAIL}
}

${WEBSERVER_SERVER_NAME} {
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}
CADDY_EOF
      ;;
    redirect-all)
      cat > "$tmp" <<CADDY_EOF
# Managed by installicious feature-caddy. Edit CADDY_HTTP_POLICY /
# WEBSERVER_SERVER_NAME / CADDY_ACME_EMAIL via the config editor and
# re-run; this file is regenerated.
#
# Policy: redirect-all (every HTTP request -> HTTPS).

{
    email ${CADDY_ACME_EMAIL}
}

${WEBSERVER_SERVER_NAME} {
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}

# Catch any unmatched :80 request (other Host headers, LAN IP, etc.)
# and 301 to HTTPS so the policy is consistent across all clients.
# Caddy's auto-HTTPS still serves the named site's ACME challenge
# before this block evaluates.
http:// {
    redir https://{host}{uri} 301
}
CADDY_EOF
      ;;
    deny-http)
      cat > "$tmp" <<CADDY_EOF
# Managed by installicious feature-caddy. Edit CADDY_HTTP_POLICY /
# WEBSERVER_SERVER_NAME / CADDY_ACME_EMAIL via the config editor and
# re-run; this file is regenerated.
#
# Policy: deny-http (HTTP closed except for ACME challenge files).

{
    email ${CADDY_ACME_EMAIL}
    auto_https disable_redirects
}

${WEBSERVER_SERVER_NAME} {
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}

http:// {
    @acme path /.well-known/acme-challenge/*
    handle @acme {
        root * ${WEBSERVER_DOC_ROOT}
        file_server
    }
    handle {
        respond 444
    }
}
CADDY_EOF
      ;;
    *)
      rm -f "$tmp"
      log_fail "Unknown CADDY_HTTP_POLICY: '$CADDY_HTTP_POLICY'."
      return 1
      ;;
  esac
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

  # ---- config sanity ----
  case "$CADDY_HTTP_POLICY" in
    redirect-all|redirect-name|deny-http) ;;
    *)
      log_fail "Unknown CADDY_HTTP_POLICY: '$CADDY_HTTP_POLICY'."
      status_mark_failed "$II_ID" "unknown HTTP policy"
      echo -e "[ \e[0;31mFAIL\e[0m ] CADDY_HTTP_POLICY must be 'redirect-all', 'redirect-name', or 'deny-http'."
      return 2
      ;;
  esac
  if [[ -z $CADDY_ACME_EMAIL ]]; then
    log_fail "CADDY_ACME_EMAIL is empty."
    status_mark_failed "$II_ID" "ACME email missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] Caddy needs CADDY_ACME_EMAIL for Let's Encrypt registration."
    echo -e "         Re-run installicious and set it in the configuration editor."
    return 2
  fi

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

  log_info "Writing Caddyfile (policy=$CADDY_HTTP_POLICY root=$WEBSERVER_DOC_ROOT server_name=$WEBSERVER_SERVER_NAME)."
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
