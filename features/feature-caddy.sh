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
II_VERSION="6"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_APT_PACKAGES="caddy"
II_RESTRICT_TO_ROLES="webserver weewx"
II_OPTIONAL_GROUP="webserver-under-construction"
# Caddy has its own built-in ACME client and HTTP policy controls, so
# webserver-ssl is deliberately NOT in this group. CADDY_HTTP_POLICY
# mirrors the WEBSERVER_SSL_HTTP_POLICY values for parity but plugs
# into Caddy's own auto-HTTPS pipeline. WEBSERVER_SSL_EMAIL is the
# same email used by certbot for the other backends; Caddy reuses it
# for its ACME account (LE doesn't care which client supplied it).
# Optional for Caddy — if blank, Caddy registers anonymously.
II_EDITABLE_CONFIG="CADDY_HTTP_POLICY WEBSERVER_SSL_EMAIL"
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
WEBSERVER_SSL_EMAIL="${WEBSERVER_SSL_EMAIL:-}"
if [[ -z ${WEBSERVER_SERVER_NAME:-} ]]; then
  WEBSERVER_SERVER_NAME=$(hostname -f 2>/dev/null)
  [[ -z $WEBSERVER_SERVER_NAME || $WEBSERVER_SERVER_NAME == "(none)" ]] && WEBSERVER_SERVER_NAME=$(hostname 2>/dev/null)
  [[ -z $WEBSERVER_SERVER_NAME ]] && WEBSERVER_SERVER_NAME="localhost"
fi

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_FALLBACK_CERT="${PATH_STATE:-/etc/installicious/state}/caddy-fallback.crt"
CADDY_FALLBACK_KEY="${PATH_STATE:-/etc/installicious/state}/caddy-fallback.key"

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

# Generate a self-signed fallback cert for $WEBSERVER_SERVER_NAME under
# $PATH_STATE so the Caddyfile's :443 catch-all has something concrete to
# present when an HTTPS request arrives with a non-matching SNI (e.g. the
# user typed https://192.168.2.12). Without this, Caddy refuses the TLS
# handshake entirely and the browser shows ERR_SSL_PROTOCOL_ERROR.
#
# Why a real cert file and not `tls internal`: Caddy's internal CA needs
# a concrete hostname to issue a cert FOR, and a bare `:443` site has no
# hostname for it to anchor on. Pointing `tls` at an explicit
# cert/key pair works because Caddy just presents the cert for any SNI
# arriving on that listener — same trick nginx uses with
# `listen 443 ssl default_server`.
#
# Regenerated on every install so the CN tracks WEBSERVER_SERVER_NAME.
_ensure_fallback_cert() {
  local dir
  dir=$(dirname "$CADDY_FALLBACK_CERT")
  sudo mkdir -p "$dir" || return 1

  log_info "Generating self-signed fallback cert for unmatched-SNI HTTPS (CN=$WEBSERVER_SERVER_NAME)."
  if ! sudo openssl req -x509 -newkey rsa:2048 -nodes \
       -keyout "$CADDY_FALLBACK_KEY" \
       -out    "$CADDY_FALLBACK_CERT" \
       -days   3650 \
       -subj   "/CN=${WEBSERVER_SERVER_NAME}" \
       -addext "subjectAltName=DNS:${WEBSERVER_SERVER_NAME}" \
       >/dev/null 2>>"$FILE_LOG_INSTALLER"; then
    log_fail "openssl failed to generate fallback cert."
    return 1
  fi

  # The caddy apt package creates a `caddy` system user that the service
  # runs as. The cert + key need to be readable by it.
  sudo chown caddy:caddy "$CADDY_FALLBACK_CERT" "$CADDY_FALLBACK_KEY" 2>/dev/null || true
  sudo chmod 0644 "$CADDY_FALLBACK_CERT" 2>/dev/null || true
  sudo chmod 0640 "$CADDY_FALLBACK_KEY"  2>/dev/null || true
  return 0
}

_remove_fallback_cert() {
  [[ -f $CADDY_FALLBACK_CERT ]] && sudo rm -f "$CADDY_FALLBACK_CERT"
  [[ -f $CADDY_FALLBACK_KEY  ]] && sudo rm -f "$CADDY_FALLBACK_KEY"
}

write_caddyfile() {
  local tmp
  tmp=$(mktemp) || return 1

  # Caddy's `email` global directive is optional. When WEBSERVER_SSL_EMAIL
  # is non-empty we render an empty global block with just an "email"
  # line; when blank we omit the global block entirely so Caddy uses
  # anonymous ACME registration. (The "auto_https disable_redirects"
  # directive for deny-http needs its own block regardless — see below.)
  local global_email_line=""
  [[ -n $WEBSERVER_SSL_EMAIL ]] && global_email_line="email ${WEBSERVER_SSL_EMAIL}"

  case "$CADDY_HTTP_POLICY" in
    redirect-name)
      {
        cat <<CADDY_EOF
# Managed by installicious feature-caddy. Edit CADDY_HTTP_POLICY /
# WEBSERVER_SERVER_NAME / WEBSERVER_SSL_EMAIL via the config editor
# and re-run; this file is regenerated.
#
# Policy: redirect-name (only the canonical host redirects; other
# hosts on :80 serve plain HTTP).
#
# IMPORTANT: Caddy's auto-HTTPS by default creates a :80 server that
# redirects ALL hosts to :443 — that would effectively turn this
# policy into redirect-all. We override that by writing an explicit
# http:// block below with a @canonical matcher, so only requests
# whose Host header matches WEBSERVER_SERVER_NAME redirect. Caddy
# still inserts its ACME challenge handler at the top of our explicit
# route, so HTTP-01 renewals keep working.
CADDY_EOF
        if [[ -n $global_email_line ]]; then
          cat <<CADDY_EOF

{
    ${global_email_line}
}
CADDY_EOF
        fi
        cat <<CADDY_EOF

${WEBSERVER_SERVER_NAME} {
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}

http:// {
    @canonical host ${WEBSERVER_SERVER_NAME}
    handle @canonical {
        redir https://{host}{uri} 301
    }
    handle {
        root * ${WEBSERVER_DOC_ROOT}
        file_server
    }
}

# :443 catch-all for unmatched SNI (LAN IP / other Host). Presents the
# self-signed fallback cert (CN=${WEBSERVER_SERVER_NAME}); browser
# shows a cert-name warning but the page loads after click-through.
# Same UX nginx/apache deliver with their default_server :443 blocks.
:443 {
    tls ${CADDY_FALLBACK_CERT} ${CADDY_FALLBACK_KEY}
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}
CADDY_EOF
      } > "$tmp"
      ;;
    redirect-all)
      {
        cat <<CADDY_EOF
# Managed by installicious feature-caddy. Edit CADDY_HTTP_POLICY /
# WEBSERVER_SERVER_NAME / WEBSERVER_SSL_EMAIL via the config editor
# and re-run; this file is regenerated.
#
# Policy: redirect-all (every HTTP request -> HTTPS).
CADDY_EOF
        if [[ -n $global_email_line ]]; then
          cat <<CADDY_EOF

{
    ${global_email_line}
}
CADDY_EOF
        fi
        cat <<CADDY_EOF

${WEBSERVER_SERVER_NAME} {
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}

# Catch any unmatched :80 request and 301 to HTTPS on the incoming host.
# The :443 catch-all below presents the self-signed fallback cert so the
# resulting HTTPS connection actually completes (with a cert-name warning
# the user can click through), instead of falling into ERR_SSL_PROTOCOL_
# ERROR.
http:// {
    redir https://{host}{uri} 301
}

:443 {
    tls ${CADDY_FALLBACK_CERT} ${CADDY_FALLBACK_KEY}
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}
CADDY_EOF
      } > "$tmp"
      ;;
    deny-http)
      # deny-http needs auto_https disable_redirects in the global block;
      # combine with the optional email line so the block is always
      # emitted in this policy.
      {
        cat <<CADDY_EOF
# Managed by installicious feature-caddy. Edit CADDY_HTTP_POLICY /
# WEBSERVER_SERVER_NAME / WEBSERVER_SSL_EMAIL via the config editor
# and re-run; this file is regenerated.
#
# Policy: deny-http (HTTP closed except for ACME challenge files).

{
    auto_https disable_redirects
CADDY_EOF
        [[ -n $global_email_line ]] && echo "    ${global_email_line}"
        cat <<CADDY_EOF
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

# :443 catch-all for unmatched SNI — same self-signed fallback as the
# other policies (cert-name warning, page loads). deny-http only closes
# plain HTTP; it doesn't make HTTPS-by-IP fail.
:443 {
    tls ${CADDY_FALLBACK_CERT} ${CADDY_FALLBACK_KEY}
    root * ${WEBSERVER_DOC_ROOT}
    file_server
}
CADDY_EOF
      } > "$tmp"
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
  if [[ -z $WEBSERVER_SSL_EMAIL ]]; then
    log_warn "WEBSERVER_SSL_EMAIL is empty; Caddy will register with Let's Encrypt anonymously (no renewal reminders)."
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

  # Generate the self-signed fallback cert used by the :443 catch-all.
  # Must exist before Caddy validates / loads the Caddyfile because the
  # config references the cert + key files directly.
  if ! _ensure_fallback_cert; then
    status_mark_failed "$II_ID" "fallback cert generation failed"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not generate the Caddy fallback cert."
    return 1
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

  # Remove the self-signed fallback cert + key we generated.
  _remove_fallback_cert

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
