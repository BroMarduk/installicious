#!/bin/bash

# Module:      Web Server - HTTPS / SSL (Let's Encrypt)
# Description: Issues a Let's Encrypt certificate via certbot and wires
#              it into the active web-server backend (nginx or apache).
#              Adds an HTTP->HTTPS redirect, enables HSTS, and certbot's
#              auto-renewal timer takes over from there.
#
#              Challenge method is configurable (WEBSERVER_SSL_METHOD):
#                "http"           HTTP-01 via the backend's plugin.
#                                 Needs port 80 reachable from the
#                                 internet. Fails when the domain is
#                                 behind a proxy like Cloudflare (the
#                                 proxy returns 404 for the challenge
#                                 path).
#                "dns-cloudflare" DNS-01 via the Cloudflare API. Works
#                                 with the proxy enabled. Requires a
#                                 CF API token in WEBSERVER_SSL_CF_TOKEN
#                                 with Zone:DNS:Edit on the relevant
#                                 zone. The token is written to
#                                 $PATH_STATE/cloudflare.ini (0600,
#                                 root-only) for certbot to read.
#
#              Backend coverage (independent of challenge method):
#                nginx     - certbot installs via --installer nginx (full)
#                apache    - certbot installs via --installer apache (full)
#                lighttpd  - certbot has no official lighttpd plugin;
#                            the cert is obtained via certonly (HTTP or
#                            DNS challenge as chosen) and a manual
#                            lighttpd config recipe is printed for the
#                            user. Returns rc=2.
#                caddy     - never reached (not in caddy's
#                            II_OPTIONAL_GROUP). Defensive skip.
#
#              Hidden child of nginx / apache / lighttpd via their
#              II_OPTIONAL_GROUP so it only surfaces in the post-radio
#              sub-menu. The user MUST set WEBSERVER_SERVER_NAME (real
#              FQDN with live DNS) and WEBSERVER_SSL_EMAIL via the
#              editor before install; otherwise certbot fails or rate-
#              limits us.
#
#              Reference: scripts/weewx-nginx-ssl.sh — the original
#              weewx-specific recipe this feature generalizes from.

# === II_MANIFEST_BEGIN ===
II_ID="webserver-ssl"
II_TITLE="HTTPS / SSL (Let's Encrypt)"
II_CATEGORY="feature"
II_VERSION="2"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_EDITABLE_CONFIG="WEBSERVER_SSL_EMAIL WEBSERVER_SSL_METHOD WEBSERVER_SSL_CF_TOKEN"
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
WEBSERVER_SSL_METHOD="${WEBSERVER_SSL_METHOD:-http}"
WEBSERVER_SSL_CF_TOKEN="${WEBSERVER_SSL_CF_TOKEN:-}"
WEBSERVER_DOC_ROOT="${WEBSERVER_DOC_ROOT:-/var/www/html}"

CLOUDFLARE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/cloudflare.ini"

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

# Write $WEBSERVER_SSL_CF_TOKEN into the certbot Cloudflare credentials
# file at $CLOUDFLARE_CREDS_FILE (mode 0600, root-owned). Returns
# non-zero if the token is empty or the write fails.
_write_cf_credentials() {
  if [[ -z $WEBSERVER_SSL_CF_TOKEN ]]; then
    log_fail "WEBSERVER_SSL_CF_TOKEN is empty; cannot write Cloudflare credentials."
    return 1
  fi
  local dir tmp
  dir=$(dirname "$CLOUDFLARE_CREDS_FILE")
  sudo mkdir -p "$dir" || return 1
  tmp=$(mktemp) || return 1
  printf 'dns_cloudflare_api_token = %s\n' "$WEBSERVER_SSL_CF_TOKEN" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  sudo install -m 0600 -o root -g root "$tmp" "$CLOUDFLARE_CREDS_FILE" \
    || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  log_info "Wrote Cloudflare credentials to $CLOUDFLARE_CREDS_FILE (mode 0600)."
  return 0
}

# Remove the Cloudflare credentials file. Best-effort.
_remove_cf_credentials() {
  if [[ -f $CLOUDFLARE_CREDS_FILE ]]; then
    sudo rm -f "$CLOUDFLARE_CREDS_FILE"
    log_info "Removed Cloudflare credentials file."
  fi
}

# Build the certbot challenge-method argument vector based on
# $WEBSERVER_SSL_METHOD. Writes to global $_CB_ARGS array.
_build_cb_challenge_args() {
  _CB_ARGS=()
  case "$WEBSERVER_SSL_METHOD" in
    http)
      # HTTP-01 args depend on whether we have an installer plugin
      # (nginx/apache combine auth+installer in one flag) or are doing
      # certonly+webroot for lighttpd. Caller fills these in instead;
      # this branch leaves _CB_ARGS empty.
      ;;
    dns-cloudflare)
      _CB_ARGS+=(--authenticator dns-cloudflare)
      _CB_ARGS+=(--dns-cloudflare-credentials "$CLOUDFLARE_CREDS_FILE")
      _CB_ARGS+=(--dns-cloudflare-propagation-seconds 30)
      ;;
    *)
      log_fail "Unknown WEBSERVER_SSL_METHOD: '$WEBSERVER_SSL_METHOD' (expected 'http' or 'dns-cloudflare')."
      return 1
      ;;
  esac
  return 0
}

# Apt packages required for the chosen method+backend combination.
# Writes to global $_CB_PKGS array.
_build_cb_apt_packages() {
  local backend="$1"
  _CB_PKGS=(certbot)
  case "$backend" in
    nginx)    _CB_PKGS+=(python3-certbot-nginx) ;;
    apache)   _CB_PKGS+=(python3-certbot-apache) ;;
    lighttpd) ;;  # no plugin
  esac
  [[ $WEBSERVER_SSL_METHOD == "dns-cloudflare" ]] && _CB_PKGS+=(python3-certbot-dns-cloudflare)
}

_run_cert_nginx_or_apache() {
  local backend="$1" plugin
  case "$backend" in
    nginx)  plugin="nginx"  ;;
    apache) plugin="apache" ;;
  esac

  local -a args=()
  case "$WEBSERVER_SSL_METHOD" in
    http)
      # --nginx / --apache is the legacy combined auth+installer flag.
      args+=("--$plugin")
      ;;
    dns-cloudflare)
      # Use dns-cloudflare as the authenticator and the backend plugin
      # only as the installer.
      args+=(--authenticator dns-cloudflare)
      args+=(--installer "$plugin")
      args+=(--dns-cloudflare-credentials "$CLOUDFLARE_CREDS_FILE")
      args+=(--dns-cloudflare-propagation-seconds 30)
      ;;
  esac

  log_info "Running certbot for $backend ($WEBSERVER_SSL_METHOD) — domain $WEBSERVER_SERVER_NAME."
  sudo certbot "${args[@]}" \
    -d "$WEBSERVER_SERVER_NAME" \
    -m "$WEBSERVER_SSL_EMAIL" \
    --agree-tos --no-eff-email --non-interactive \
    --redirect --hsts --keep-until-expiring 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  return ${PIPESTATUS[0]}
}

_run_cert_lighttpd_certonly() {
  local -a args=(certonly)
  case "$WEBSERVER_SSL_METHOD" in
    http)
      args+=(--webroot -w "$WEBSERVER_DOC_ROOT")
      ;;
    dns-cloudflare)
      args+=(--dns-cloudflare)
      args+=(--dns-cloudflare-credentials "$CLOUDFLARE_CREDS_FILE")
      args+=(--dns-cloudflare-propagation-seconds 30)
      ;;
  esac

  log_info "Running certbot certonly for lighttpd ($WEBSERVER_SSL_METHOD) — domain $WEBSERVER_SERVER_NAME."
  sudo certbot "${args[@]}" \
    -d "$WEBSERVER_SERVER_NAME" \
    -m "$WEBSERVER_SSL_EMAIL" \
    --agree-tos --no-eff-email --non-interactive --keep-until-expiring 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  return ${PIPESTATUS[0]}
}

_print_lighttpd_manual_recipe() {
  cat >&2 <<EOF
[ WARN ] HTTPS for lighttpd requires manual config in addition to the
         cert that was just obtained. certbot has no official lighttpd
         plugin, so the next step is yours:

           sudo lighty-enable-mod ssl

         then edit /etc/lighttpd/conf-available/10-ssl.conf:
           ssl.pemfile = "/etc/letsencrypt/live/$WEBSERVER_SERVER_NAME/fullchain.pem"
           ssl.privkey  = "/etc/letsencrypt/live/$WEBSERVER_SERVER_NAME/privkey.pem"

         and reload:  sudo systemctl reload lighttpd
EOF
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
    return 2
  fi
  if [[ -z $WEBSERVER_SSL_EMAIL ]]; then
    log_fail "WEBSERVER_SSL_EMAIL is empty."
    status_mark_failed "$II_ID" "email is empty"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS needs WEBSERVER_SSL_EMAIL for Let's Encrypt registration."
    return 2
  fi
  case "$WEBSERVER_SSL_METHOD" in
    http) ;;
    dns-cloudflare)
      if [[ -z $WEBSERVER_SSL_CF_TOKEN ]]; then
        log_fail "WEBSERVER_SSL_METHOD=dns-cloudflare requires WEBSERVER_SSL_CF_TOKEN."
        status_mark_failed "$II_ID" "Cloudflare token missing"
        echo -e "[ \e[0;31mFAIL\e[0m ] dns-cloudflare needs WEBSERVER_SSL_CF_TOKEN."
        echo -e "         Create a token at https://dash.cloudflare.com/profile/api-tokens"
        echo -e "         (template: 'Edit zone DNS' scoped to your domain's zone) and"
        echo -e "         re-run installicious."
        return 2
      fi
      ;;
    *)
      log_fail "Unknown WEBSERVER_SSL_METHOD: '$WEBSERVER_SSL_METHOD'."
      status_mark_failed "$II_ID" "unknown SSL method"
      echo -e "[ \e[0;31mFAIL\e[0m ] WEBSERVER_SSL_METHOD must be 'http' or 'dns-cloudflare'."
      return 2
      ;;
  esac

  # ---- detect backend ----
  local backend
  backend=$(_detect_backend) || {
    log_fail "No web-server backend detected; nothing to configure SSL for."
    status_mark_failed "$II_ID" "no backend installed"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS feature ran but no web-server backend is installed."
    return 1
  }
  log_info "Detected backend: $backend"

  # ---- caddy: skip entirely ----
  if [[ $backend == "caddy" ]]; then
    log_warn "Caddy backend detected — Caddy auto-handles HTTPS; nothing to do."
    echo -e "[  \e[0;32mOK\e[0m  ] Caddy already auto-handles HTTPS — no manual SSL setup needed."
    status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
    return 0
  fi

  # ---- apt deps ----
  _build_cb_apt_packages "$backend"
  log_info "Ensuring apt packages: ${_CB_PKGS[*]}"
  installer_apt_record_install "$STATUS_FILE" "${_CB_PKGS[@]}"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "apt install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install certbot packages. Error Code: $rc."
    return $rc
  fi

  # ---- credentials file for dns-cloudflare ----
  if [[ $WEBSERVER_SSL_METHOD == "dns-cloudflare" ]]; then
    _write_cf_credentials || {
      status_mark_failed "$II_ID" "could not write Cloudflare credentials"
      return 1
    }
  fi

  # ---- run certbot ----
  case "$backend" in
    nginx|apache)
      _run_cert_nginx_or_apache "$backend"
      rc=$?
      ;;
    lighttpd)
      _run_cert_lighttpd_certonly
      rc=$?
      if [[ $rc -eq 0 ]]; then
        _print_lighttpd_manual_recipe
        rc=2  # cert obtained but server config still pending — surface as soft-fail.
      fi
      ;;
  esac

  if [[ $rc -ne 0 && $rc -ne 2 ]]; then
    status_mark_failed "$II_ID" "$backend SSL setup failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] HTTPS setup did not complete for $backend (rc=$rc)."
    return $rc
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  if [[ $rc -eq 2 ]]; then
    log_warn "Cert obtained for $WEBSERVER_SERVER_NAME but manual lighttpd config still required (see recipe above)."
    echo -e "[ \e[0;33mWARN\e[0m ] Cert obtained — finish the lighttpd config manually per the recipe above."
  else
    log_ok "HTTPS configured for $backend on $WEBSERVER_SERVER_NAME via $WEBSERVER_SSL_METHOD."
    echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully configured HTTPS for $backend ($WEBSERVER_SSL_METHOD)."
  fi
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
  # added: the apt packages (iff we installed them) and the Cloudflare
  # credentials file (a secret — definitely don't leave it behind).
  _remove_cf_credentials

  if apt_is_installed python3-certbot-dns-cloudflare; then
    installer_apt_revert "$STATUS_FILE" python3-certbot-dns-cloudflare
  fi
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
