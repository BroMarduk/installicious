#!/bin/bash

# Module:      Web Server - HTTPS / SSL (Let's Encrypt)
# Description: Issues a Let's Encrypt cert via certbot (in certonly
#              mode, so certbot only acquires the cert and never edits
#              the backend's config), then writes a managed site config
#              that binds :443 to the cert and routes :80 according to
#              the configured WEBSERVER_SSL_HTTP_POLICY.
#
#              Challenge method is configurable (WEBSERVER_SSL_METHOD):
#                "http"           HTTP-01 via webroot challenge under
#                                 $WEBSERVER_DOC_ROOT/.well-known/acme-
#                                 challenge/. Needs port 80 reachable
#                                 from the internet. Fails when the
#                                 domain is behind a proxy that
#                                 doesn't pass that path through (e.g.
#                                 Cloudflare orange-cloud).
#                "dns-cloudflare" DNS-01 via the Cloudflare API. Works
#                                 with the proxy enabled. Requires a
#                                 CF API token in WEBSERVER_SSL_CF_TOKEN
#                                 with Zone:DNS:Edit on the zone. The
#                                 token is written to
#                                 $PATH_STATE/cloudflare.ini (0600,
#                                 root-only) for certbot to read.
#
#              HTTP policy (WEBSERVER_SSL_HTTP_POLICY):
#                "redirect-all"  (default) any HTTP request -> HTTPS
#                "redirect-name" HTTP -> HTTPS only when Host matches
#                                WEBSERVER_SERVER_NAME; other hosts /
#                                IP access serve plain HTTP
#                "deny-http"     :80 returns 444/closes for everything
#                                except the ACME challenge path
#
#              All three policies leave /.well-known/acme-challenge/
#              reachable on :80 so certbot's HTTP-01 renewals keep
#              working without manual intervention.
#
#              Backend coverage (all three policies, both methods):
#                nginx     - replaces /etc/nginx/sites-available/default
#                apache    - replaces /etc/apache2/sites-available/000-
#                            default.conf + /etc/apache2/ports.conf,
#                            enables ssl + headers modules
#                lighttpd  - rewrites /etc/lighttpd/conf-available/99-
#                            installicious-ssl.conf, enables it via
#                            symlink, loads mod_openssl
#                caddy     - never reached (not in caddy's
#                            II_OPTIONAL_GROUP); defensive skip.
#
#              The pre-SSL site config is snapshotted under this
#              feature's backup ID, so --uninstall restores the HTTP-
#              only state written by feature-nginx / feature-apache /
#              feature-lighttpd. Let's Encrypt cert files under
#              /etc/letsencrypt are preserved on uninstall (LE rate-
#              limits issuance).
#
#              Reference: scripts/weewx-nginx-ssl.sh - the original
#              weewx-specific recipe this feature generalized from.

# === II_MANIFEST_BEGIN ===
II_ID="webserver-ssl"
II_TITLE="HTTPS / SSL (Let's Encrypt)"
II_CATEGORY="feature"
II_VERSION="4"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_EDITABLE_CONFIG="WEBSERVER_SSL_EMAIL WEBSERVER_SSL_METHOD WEBSERVER_SSL_CF_TOKEN WEBSERVER_SSL_HTTP_POLICY"
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
WEBSERVER_SERVER_NAME="${WEBSERVER_SERVER_NAME:-}"
WEBSERVER_SSL_EMAIL="${WEBSERVER_SSL_EMAIL:-}"
WEBSERVER_SSL_METHOD="${WEBSERVER_SSL_METHOD:-http}"
WEBSERVER_SSL_CF_TOKEN="${WEBSERVER_SSL_CF_TOKEN:-}"
WEBSERVER_SSL_HTTP_POLICY="${WEBSERVER_SSL_HTTP_POLICY:-redirect-all}"
WEBSERVER_DOC_ROOT="${WEBSERVER_DOC_ROOT:-/var/www/html}"
WEBSERVER_PORT="${WEBSERVER_PORT:-80}"

CLOUDFLARE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/cloudflare.ini"
LIGHTTPD_SSL_CONF_AVAILABLE="/etc/lighttpd/conf-available/99-installicious-ssl.conf"
LIGHTTPD_SSL_CONF_ENABLED="/etc/lighttpd/conf-enabled/99-installicious-ssl.conf"
NGINX_DEFAULT_SITE="/etc/nginx/sites-available/default"
APACHE_PORTS_CONF="/etc/apache2/ports.conf"
APACHE_DEFAULT_VHOST="/etc/apache2/sites-available/000-default.conf"

# Suppress python3-cloudflare 2.20.x PendingDeprecationWarning that the
# certbot-dns-cloudflare plugin triggers; cert issuance is unaffected.
_CERTBOT_ENV=(env PYTHONWARNINGS=ignore::PendingDeprecationWarning)

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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_detect_backend() {
  if apt_is_installed nginx;    then echo "nginx";    return 0; fi
  if apt_is_installed apache2;  then echo "apache";   return 0; fi
  if apt_is_installed lighttpd; then echo "lighttpd"; return 0; fi
  if apt_is_installed caddy;    then echo "caddy";    return 0; fi
  return 1
}

_looks_like_real_domain() {
  local name="$1"
  [[ -z $name ]] && return 1
  [[ $name == "localhost" || $name == "_" ]] && return 1
  [[ $name != *.*  ]] && return 1
  return 0
}

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

_remove_cf_credentials() {
  if [[ -f $CLOUDFLARE_CREDS_FILE ]]; then
    sudo rm -f "$CLOUDFLARE_CREDS_FILE"
    log_info "Removed Cloudflare credentials file."
  fi
}

# Build the certbot args for an "obtain only" cert request. Webroot for
# HTTP-01 (works for any backend since we control :80), dns-cloudflare
# for DNS-01. Caller appends the domain + email + housekeeping flags.
_build_certonly_args() {
  _CERTONLY_ARGS=(certonly)
  case "$WEBSERVER_SSL_METHOD" in
    http)
      sudo mkdir -p "$WEBSERVER_DOC_ROOT" 2>/dev/null || true
      _CERTONLY_ARGS+=(--webroot -w "$WEBSERVER_DOC_ROOT")
      ;;
    dns-cloudflare)
      _CERTONLY_ARGS+=(--dns-cloudflare)
      _CERTONLY_ARGS+=(--dns-cloudflare-credentials "$CLOUDFLARE_CREDS_FILE")
      _CERTONLY_ARGS+=(--dns-cloudflare-propagation-seconds 30)
      ;;
    *)
      log_fail "Unknown WEBSERVER_SSL_METHOD: '$WEBSERVER_SSL_METHOD'."
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Site-config templates (per backend, per policy)
# ---------------------------------------------------------------------------

# Renders an nginx :80 location block for the policy "/ catch-all" body.
_nginx_policy_default_action() {
  case "$WEBSERVER_SSL_HTTP_POLICY" in
    redirect-all)
      cat <<'EOF'
    location / {
        return 301 https://$host$request_uri;
    }
EOF
      ;;
    redirect-name)
      # default_server catches non-matching hosts; serve them plain.
      cat <<EOF
    location / {
        root ${WEBSERVER_DOC_ROOT};
        index index.html index.htm index.nginx-debian.html;
        try_files \$uri \$uri/ =404;
    }
EOF
      ;;
    deny-http)
      cat <<'EOF'
    location / {
        return 444;
    }
EOF
      ;;
  esac
}

_write_nginx_site_config() {
  local tmp
  tmp=$(mktemp) || return 1

  # The :80 named server matches WEBSERVER_SERVER_NAME and always
  # redirects to HTTPS (this is the user's canonical hostname).
  # The :80 default_server catches IP / other-host requests and behaves
  # per WEBSERVER_SSL_HTTP_POLICY. Both expose ACME so renewals work.
  cat > "$tmp" <<NGX_EOF
# Managed by installicious feature-webserver-ssl. Regenerated whenever
# WEBSERVER_SERVER_NAME / WEBSERVER_SSL_* keys change.

# Canonical :80 -> :443 redirect for the configured hostname.
server {
    listen 80;
    listen [::]:80;
    server_name ${WEBSERVER_SERVER_NAME};

    location /.well-known/acme-challenge/ {
        root ${WEBSERVER_DOC_ROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Catch-all :80 for IP access / other Host values. Behavior depends on
# WEBSERVER_SSL_HTTP_POLICY (${WEBSERVER_SSL_HTTP_POLICY}).
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root ${WEBSERVER_DOC_ROOT};
    }

$(_nginx_policy_default_action)
}

# HTTPS site.
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name ${WEBSERVER_SERVER_NAME};

    ssl_certificate     /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root ${WEBSERVER_DOC_ROOT};
    index index.html index.htm index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGX_EOF
  sudo install -m 0644 "$tmp" "$NGINX_DEFAULT_SITE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# Renders an apache :80 default VirtualHost body matching the policy.
_apache_policy_default_action() {
  case "$WEBSERVER_SSL_HTTP_POLICY" in
    redirect-all)
      cat <<EOF
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/.well-known/acme-challenge/
    RewriteRule ^/(.*)\$ https://%{HTTP_HOST}/\$1 [R=301,L]
EOF
      ;;
    redirect-name)
      cat <<EOF
    # Default vhost serves plain HTTP; the named :80 vhost (below)
    # handles the canonical-domain HTTPS redirect.
    DocumentRoot ${WEBSERVER_DOC_ROOT}
EOF
      ;;
    deny-http)
      cat <<EOF
    <Location />
        Require all denied
    </Location>
    <Location /.well-known/acme-challenge/>
        Require all granted
    </Location>
    DocumentRoot ${WEBSERVER_DOC_ROOT}
EOF
      ;;
  esac
}

_write_apache_ports_conf() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<APACHE_EOF
# Managed by installicious feature-webserver-ssl.
Listen 80

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

_write_apache_vhost() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<APACHE_EOF
# Managed by installicious feature-webserver-ssl. Combined :80 (policy
# = ${WEBSERVER_SSL_HTTP_POLICY}) and :443 (SSL) VirtualHosts.

# Catch-all :80 for IP access / other Host values.
<VirtualHost *:80>
    ServerName _default_
    DocumentRoot ${WEBSERVER_DOC_ROOT}

    Alias /.well-known/acme-challenge/ ${WEBSERVER_DOC_ROOT}/.well-known/acme-challenge/
    <Directory "${WEBSERVER_DOC_ROOT}/.well-known/acme-challenge/">
        Require all granted
    </Directory>

$(_apache_policy_default_action)

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>

# Canonical :80 vhost for the configured hostname -- always redirects
# to HTTPS (with ACME exception).
<VirtualHost *:80>
    ServerName ${WEBSERVER_SERVER_NAME}

    Alias /.well-known/acme-challenge/ ${WEBSERVER_DOC_ROOT}/.well-known/acme-challenge/
    <Directory "${WEBSERVER_DOC_ROOT}/.well-known/acme-challenge/">
        Require all granted
    </Directory>

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/.well-known/acme-challenge/
    RewriteRule ^/(.*)\$ https://${WEBSERVER_SERVER_NAME}/\$1 [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName ${WEBSERVER_SERVER_NAME}
    DocumentRoot ${WEBSERVER_DOC_ROOT}

    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/privkey.pem

    ErrorLog \${APACHE_LOG_DIR}/ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/ssl-access.log combined
</VirtualHost>
</IfModule>
APACHE_EOF
  sudo install -m 0644 "$tmp" "$APACHE_DEFAULT_VHOST" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# Lighttpd config templates the redirect block based on policy. Always
# exempt the ACME challenge URL prefix so HTTP-01 renewals work.
_lighttpd_policy_block() {
  case "$WEBSERVER_SSL_HTTP_POLICY" in
    redirect-all)
      cat <<'EOF'
# redirect-all: any HTTP request -> HTTPS (except ACME challenge).
$HTTP["scheme"] == "http" {
    $HTTP["url"] !~ "^/\.well-known/acme-challenge/" {
        $HTTP["host"] =~ ".*" {
            url.redirect = (".*" => "https://%0$0")
        }
    }
}
EOF
      ;;
    redirect-name)
      cat <<EOF
# redirect-name: redirect HTTP -> HTTPS only when Host matches
# WEBSERVER_SERVER_NAME; other Host values keep plain HTTP.
\$HTTP["scheme"] == "http" {
    \$HTTP["url"] !~ "^/\\.well-known/acme-challenge/" {
        \$HTTP["host"] == "${WEBSERVER_SERVER_NAME}" {
            url.redirect = (".*" => "https://%0\$0")
        }
    }
}
EOF
      ;;
    deny-http)
      cat <<'EOF'
# deny-http: block plain HTTP entirely except for ACME challenge.
$HTTP["scheme"] == "http" {
    $HTTP["url"] !~ "^/\.well-known/acme-challenge/" {
        url.access-deny = ( "" )
    }
}
EOF
      ;;
  esac
}

_write_lighttpd_ssl_config() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" <<LIGHTY_EOF
# Managed by installicious feature-webserver-ssl. Regenerated whenever
# WEBSERVER_SERVER_NAME / WEBSERVER_SSL_* keys change.

server.modules += ( "mod_openssl" )

\$SERVER["socket"] == ":443" {
    ssl.engine               = "enable"
    ssl.pemfile              = "/etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/fullchain.pem"
    ssl.privkey              = "/etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/privkey.pem"
    ssl.openssl.ssl-conf-cmd = ("MinProtocol" => "TLSv1.2")
}

$(_lighttpd_policy_block)
LIGHTY_EOF
  sudo install -m 0644 "$tmp" "$LIGHTTPD_SSL_CONF_AVAILABLE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"

  sudo mkdir -p "$(dirname "$LIGHTTPD_SSL_CONF_ENABLED")" || return 1
  if [[ ! -L $LIGHTTPD_SSL_CONF_ENABLED ]]; then
    sudo ln -s "../conf-available/99-installicious-ssl.conf" \
      "$LIGHTTPD_SSL_CONF_ENABLED" || return 1
  fi
  return 0
}

_remove_lighttpd_ssl_config() {
  if [[ -L $LIGHTTPD_SSL_CONF_ENABLED ]]; then
    sudo rm -f "$LIGHTTPD_SSL_CONF_ENABLED"
  fi
  if [[ -f $LIGHTTPD_SSL_CONF_AVAILABLE ]]; then
    sudo rm -f "$LIGHTTPD_SSL_CONF_AVAILABLE"
  fi
}

# Common cert issuance step shared by all backends. Sets up apt deps,
# CF credentials (if needed), and runs `certbot certonly` to obtain
# the cert into /etc/letsencrypt/live/$WEBSERVER_SERVER_NAME/. Returns
# certbot's exit code.
_obtain_cert() {
  local -a apt_pkgs=(certbot)
  [[ $WEBSERVER_SSL_METHOD == "dns-cloudflare" ]] && apt_pkgs+=(python3-certbot-dns-cloudflare)

  log_info "Ensuring apt packages: ${apt_pkgs[*]}"
  installer_apt_record_install "$STATUS_FILE" "${apt_pkgs[@]}" || return $?

  if [[ $WEBSERVER_SSL_METHOD == "dns-cloudflare" ]]; then
    _write_cf_credentials || return 1
  fi

  _build_certonly_args || return 1
  log_info "Running certbot ${_CERTONLY_ARGS[*]} (method=$WEBSERVER_SSL_METHOD, domain=$WEBSERVER_SERVER_NAME)."
  # Filter out the python3-cloudflare 2.20.x PendingDeprecationWarning
  # block. It's emitted as a plain print() in the cloudflare library
  # (not via warnings.warn()), so PYTHONWARNINGS=ignore can't suppress
  # it — sed strips the multi-line block from stderr instead. The
  # block starts at the ':PendingDeprecationWarning:' marker and ends
  # at the '  self.cf = CloudFlare' source line.
  sudo "${_CERTBOT_ENV[@]}" certbot "${_CERTONLY_ARGS[@]}" \
    -d "$WEBSERVER_SERVER_NAME" \
    -m "$WEBSERVER_SSL_EMAIL" \
    --agree-tos --no-eff-email --non-interactive --keep-until-expiring 2>&1 \
    | sed '/PendingDeprecationWarning:$/,/^  self\.cf = CloudFlare/d' \
    | tee -a "$FILE_LOG_INSTALLER"
  return ${PIPESTATUS[0]}
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

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
        return 2
      fi
      ;;
    *)
      log_fail "Unknown WEBSERVER_SSL_METHOD: '$WEBSERVER_SSL_METHOD'."
      status_mark_failed "$II_ID" "unknown SSL method"
      return 2
      ;;
  esac
  case "$WEBSERVER_SSL_HTTP_POLICY" in
    redirect-all|redirect-name|deny-http) ;;
    *)
      log_fail "Unknown WEBSERVER_SSL_HTTP_POLICY: '$WEBSERVER_SSL_HTTP_POLICY'."
      status_mark_failed "$II_ID" "unknown HTTP policy"
      echo -e "[ \e[0;31mFAIL\e[0m ] WEBSERVER_SSL_HTTP_POLICY must be 'redirect-all', 'redirect-name', or 'deny-http'."
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

  if [[ $backend == "caddy" ]]; then
    # Caddy is self-hosted ACME with its own HTTP policy knob
    # (CADDY_HTTP_POLICY in config/webserver.config, plumbed by
    # feature-caddy). webserver-ssl has nothing to do here.
    log_warn "Caddy backend detected — Caddy handles HTTPS itself; see CADDY_HTTP_POLICY."
    echo -e "[  \e[0;32mOK\e[0m  ] Caddy already auto-handles HTTPS — configure CADDY_HTTP_POLICY via feature-caddy."
    status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
    return 0
  fi

  # ---- obtain the cert ----
  _obtain_cert
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$II_ID" "certbot certonly failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] certbot did not obtain a cert for $WEBSERVER_SERVER_NAME (rc=$rc)."
    return $rc
  fi

  # ---- snapshot pre-SSL site config under this feature's backup ID ----
  # Captures whatever the backend feature wrote (HTTP-only); --uninstall
  # restores from this snapshot.
  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up pre-SSL site config under '$II_ID' snapshot."
    case "$backend" in
      nginx)    backup_create "$II_ID" "$NGINX_DEFAULT_SITE" >/dev/null || log_warn "backup_create failed; continuing." ;;
      apache)   backup_create "$II_ID" "$APACHE_DEFAULT_VHOST" "$APACHE_PORTS_CONF" >/dev/null || log_warn "backup_create failed; continuing." ;;
      lighttpd) ;;  # our SSL conf is a brand-new file; nothing to snapshot
    esac
  fi

  # ---- write the managed SSL site config ----
  log_info "Writing managed SSL config (policy=$WEBSERVER_SSL_HTTP_POLICY)."
  case "$backend" in
    nginx)
      if ! _write_nginx_site_config; then
        status_mark_failed "$II_ID" "nginx site config render failed"
        return 1
      fi
      if ! sudo nginx -t 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
        log_warn "nginx -t rejected SSL config; restoring backup."
        backup_restore_latest "$II_ID" "$NGINX_DEFAULT_SITE" || log_warn "Backup restore failed."
        status_mark_failed "$II_ID" "nginx -t rejected SSL config"
        return 1
      fi
      log_info "Reloading nginx."
      sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx \
        || log_warn "nginx reload/restart returned non-zero."
      ;;
    apache)
      # Ensure ssl + rewrite modules are enabled before writing a config
      # that uses them.
      sudo a2enmod ssl rewrite headers 2>&1 | tee -a "$FILE_LOG_INSTALLER" || true
      if ! _write_apache_ports_conf || ! _write_apache_vhost; then
        status_mark_failed "$II_ID" "apache config render failed"
        return 1
      fi
      if ! sudo apache2ctl configtest 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
        log_warn "apache2ctl configtest rejected SSL config; restoring backup."
        backup_restore_latest "$II_ID" "$APACHE_DEFAULT_VHOST" "$APACHE_PORTS_CONF" \
          || log_warn "Backup restore failed."
        status_mark_failed "$II_ID" "apache2ctl rejected SSL config"
        return 1
      fi
      log_info "Reloading apache2."
      sudo systemctl reload apache2 2>/dev/null || sudo systemctl restart apache2 \
        || log_warn "apache2 reload/restart returned non-zero."
      ;;
    lighttpd)
      if ! _write_lighttpd_ssl_config; then
        status_mark_failed "$II_ID" "lighttpd SSL config render failed"
        return 1
      fi
      if ! sudo lighttpd -t -f /etc/lighttpd/lighttpd.conf 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
        log_warn "lighttpd -t rejected SSL config; reverting."
        _remove_lighttpd_ssl_config
        status_mark_failed "$II_ID" "lighttpd -t rejected SSL config"
        return 1
      fi
      log_info "Reloading lighttpd."
      sudo systemctl reload lighttpd 2>/dev/null \
        || sudo systemctl restart lighttpd \
        || log_warn "lighttpd reload/restart returned non-zero."
      ;;
  esac

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEBSERVER"
  log_ok "HTTPS configured for $backend on $WEBSERVER_SERVER_NAME (method=$WEBSERVER_SSL_METHOD, policy=$WEBSERVER_SSL_HTTP_POLICY)."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully configured HTTPS for $backend ($WEBSERVER_SSL_HTTP_POLICY)."
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

  # Restore the pre-SSL site config from this feature's snapshot, so
  # the backend goes back to the HTTP-only config that feature-nginx /
  # feature-apache wrote. Lighttpd's managed SSL conf is removed instead.
  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring pre-SSL site config from snapshot."
    backup_restore_or_remove "$II_ID" \
      "$NGINX_DEFAULT_SITE" "$APACHE_DEFAULT_VHOST" "$APACHE_PORTS_CONF" \
      || log_warn "Site config restore returned non-zero."
  fi
  _remove_lighttpd_ssl_config

  # Reload whichever backend is installed so the reverted config takes effect.
  if   apt_is_installed nginx;    then sudo systemctl reload nginx    2>/dev/null || true
  elif apt_is_installed apache2;  then sudo systemctl reload apache2  2>/dev/null || true
  elif apt_is_installed lighttpd; then sudo systemctl reload lighttpd 2>/dev/null || true
  fi

  # certbot leaves cert files under /etc/letsencrypt; preserved on
  # uninstall (LE rate-limits issuance). Remove the Cloudflare creds
  # (it's a secret).
  _remove_cf_credentials

  if apt_is_installed python3-certbot-dns-cloudflare; then
    installer_apt_revert "$STATUS_FILE" python3-certbot-dns-cloudflare
  fi
  if apt_is_installed certbot; then
    installer_apt_revert "$STATUS_FILE" certbot
  fi

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
