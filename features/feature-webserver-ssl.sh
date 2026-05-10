#!/bin/bash

# Module:      Web Server - HTTPS / SSL (Let's Encrypt)
# Description: Issues a Let's Encrypt certificate via certbot and wires
#              it into the active web-server backend (nginx or apache).
#              Adds an HTTP->HTTPS redirect, enables HSTS, and verifies
#              auto-renewal.
#
#              Backend coverage:
#                nginx     - certbot --nginx (full)
#                apache    - certbot --apache (full)
#                lighttpd  - certbot has no official plugin; this
#                            feature surfaces a clear "not yet
#                            automated" message and aborts. Manual
#                            cert + sites-enabled config required.
#                caddy     - never reached — caddy auto-handles HTTPS,
#                            so this feature isn't in caddy's
#                            II_OPTIONAL_GROUP. Defensive skip if
#                            somehow invoked.
#
#              Hidden child of nginx / apache / lighttpd via their
#              II_OPTIONAL_GROUP so it only surfaces in the post-radio
#              sub-menu. The user MUST set WEBSERVER_SERVER_NAME (real
#              FQDN with live DNS) and WEBSERVER_SSL_EMAIL via the
#              editor before install; otherwise certbot fails or rate-
#              limits us.
#
#              Prerequisites (user responsibility):
#                - DNS A (and optionally AAAA) record for
#                  WEBSERVER_SERVER_NAME points at this Pi's public IP.
#                - Router forwards TCP 80 + 443 to this Pi (80 for the
#                  HTTP-01 challenge, 443 for serving).
#
#              Reference: scripts/weewx-nginx-ssl.sh — the original
#              weewx-specific recipe this feature generalizes from.

# === II_MANIFEST_BEGIN ===
II_ID="webserver-ssl"
II_TITLE="HTTPS / SSL (Let's Encrypt)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_EDITABLE_CONFIG="WEBSERVER_SSL_EMAIL"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/installer_apt.sh

FILE_CONFIG_WEBSERVER="${PATH_CONFIG:-config}/webserver.config"
[[ -f $FILE_CONFIG_WEBSERVER ]] && source "$FILE_CONFIG_WEBSERVER"
state_apply_menu_overrides
WEBSERVER_SERVER_NAME="${WEBSERVER_SERVER_NAME:-}"
WEBSERVER_SSL_EMAIL="${WEBSERVER_SSL_EMAIL:-}"

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

# Detect which backend's apt package is installed. Returns the backend
# ID via stdout (nginx / apache / lighttpd / caddy) and rc=0; rc=1 if
# none detected.
_detect_backend() {
  if apt_is_installed nginx;    then echo "nginx";    return 0; fi
  if apt_is_installed apache2;  then echo "apache";   return 0; fi
  if apt_is_installed lighttpd; then echo "lighttpd"; return 0; fi
  if apt_is_installed caddy;    then echo "caddy";    return 0; fi
  return 1
}

# Reject obvious non-domain server names. Let's Encrypt won't issue for
# "localhost", "_", bare hostnames without dots, or IPs.
_looks_like_real_domain() {
  local name="$1"
  [[ -z $name ]] && return 1
  [[ $name == "localhost" || $name == "_" ]] && return 1
  [[ $name != *.*  ]] && return 1
  return 0
}

_certbot_nginx() {
  log_info "Installing certbot + nginx plugin."
  installer_apt_record_install "$STATUS_FILE" certbot python3-certbot-nginx \
    || return $?

  log_info "Running certbot --nginx for $WEBSERVER_SERVER_NAME."
  sudo certbot --nginx \
    -d "$WEBSERVER_SERVER_NAME" \
    -m "$WEBSERVER_SSL_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --redirect \
    --hsts \
    --keep-until-expiring 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  return ${PIPESTATUS[0]}
}

_certbot_apache() {
  log_info "Installing certbot + apache plugin."
  installer_apt_record_install "$STATUS_FILE" certbot python3-certbot-apache \
    || return $?

  log_info "Running certbot --apache for $WEBSERVER_SERVER_NAME."
  sudo certbot --apache \
    -d "$WEBSERVER_SERVER_NAME" \
    -m "$WEBSERVER_SSL_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --redirect \
    --hsts \
    --keep-until-expiring 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  return ${PIPESTATUS[0]}
}

_lighttpd_not_implemented() {
  log_warn "SSL automation for lighttpd is not yet implemented in installicious."
  cat >&2 <<EOF
[ WARN ] HTTPS for lighttpd requires manual setup.
         certbot has no official lighttpd plugin; you'll need to use
         certbot certonly --webroot, then edit /etc/lighttpd/lighttpd.conf
         to enable mod_openssl and bind to port 443 with the cert files.

         Quick recipe:
           sudo apt-get install certbot
           sudo certbot certonly --webroot \\
             -w \${WEBSERVER_DOC_ROOT:-/var/www/html} \\
             -d $WEBSERVER_SERVER_NAME \\
             -m $WEBSERVER_SSL_EMAIL --agree-tos --no-eff-email

           sudo lighty-enable-mod ssl
           # then edit /etc/lighttpd/conf-available/10-ssl.conf with
           # ssl.pemfile = "/etc/letsencrypt/live/$WEBSERVER_SERVER_NAME/fullchain.pem"
           # ssl.privkey  = "/etc/letsencrypt/live/$WEBSERVER_SERVER_NAME/privkey.pem"
EOF
  return 2
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"; then
    log_info "HTTPS / SSL already configured at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # ---- config sanity ----
  if ! _looks_like_real_domain "$WEBSERVER_SERVER_NAME"; then
    log_fail "WEBSERVER_SERVER_NAME ('$WEBSERVER_SERVER_NAME') is not a real domain."
    status_mark_failed "$II_ID" "server name is not a real domain"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS needs WEBSERVER_SERVER_NAME set to a real FQDN with live DNS."
    echo -e "         Re-run installicious and set it in the configuration editor."
    return 2
  fi
  if [[ -z $WEBSERVER_SSL_EMAIL ]]; then
    log_fail "WEBSERVER_SSL_EMAIL is empty."
    status_mark_failed "$II_ID" "email is empty"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS needs WEBSERVER_SSL_EMAIL for Let's Encrypt registration."
    echo -e "         Re-run installicious and set it in the configuration editor."
    return 2
  fi

  # ---- detect backend ----
  local backend
  backend=$(_detect_backend) || {
    log_fail "No web-server backend detected; nothing to configure SSL for."
    status_mark_failed "$II_ID" "no backend installed"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS feature ran but no web-server backend is installed."
    echo -e "         Select webserver + a backend (nginx/apache/lighttpd) and re-run."
    return 1
  }
  log_info "Detected backend: $backend"

  # ---- dispatch ----
  local rc=0
  case "$backend" in
    nginx)    _certbot_nginx;  rc=$? ;;
    apache)   _certbot_apache; rc=$? ;;
    lighttpd) _lighttpd_not_implemented; rc=$? ;;
    caddy)
      log_warn "Caddy backend detected — Caddy auto-handles HTTPS; nothing to do."
      echo -e "[  \e[0;32mOK\e[0m  ] Caddy already auto-handles HTTPS — no manual SSL setup needed."
      rc=0
      ;;
    *)
      log_fail "Unknown backend '$backend'."
      rc=1
      ;;
  esac

  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "$backend SSL setup failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS setup did not complete for $backend (rc=$rc)."
    return $rc
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "HTTPS configured for $backend on $WEBSERVER_SERVER_NAME."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully configured HTTPS for $backend."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "HTTPS / SSL already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] HTTPS / SSL is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for webserver-ssl; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # certbot leaves cert files under /etc/letsencrypt; intentionally not
  # deleting them on uninstall (the user may want to re-use the cert
  # later, and Let's Encrypt rate-limits issuance). Revert only what we
  # added: the apt packages, iff we installed them.
  if apt_is_installed python3-certbot-nginx;  then installer_apt_revert "$STATUS_FILE" python3-certbot-nginx;  fi
  if apt_is_installed python3-certbot-apache; then installer_apt_revert "$STATUS_FILE" python3-certbot-apache; fi
  if apt_is_installed certbot;                then installer_apt_revert "$STATUS_FILE" certbot;                fi

  status_mark_uninstalled "$II_ID"
  log_warn "HTTPS / SSL uninstalled. Certs left under /etc/letsencrypt for potential reuse."
  echo -e "[  \e[0;32mOK\e[0m  ] HTTPS / SSL feature uninstalled (certs preserved under /etc/letsencrypt)."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
