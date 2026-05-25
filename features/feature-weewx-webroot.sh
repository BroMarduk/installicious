#!/bin/bash

# Module:      WeeWX as default web root
# Description: Repoints the active webserver backend's default site at
#              the WeeWX report directory ($WEEWX_WEB_DIR, default
#              /var/www/html/weewx), so a visit to http://<pi>/ shows
#              the WeeWX page instead of the backend's "It works!" /
#              "Welcome to nginx!" placeholder. Backend-agnostic — works
#              with all four (apache / nginx / lighttpd / caddy); active
#              backend is detected via the installicious status registry
#              at install time.
#
#              Symmetric uninstall: restores the backend's default-site
#              config from the pre-install snapshot via lib/backup.

# === II_MANIFEST_BEGIN ===
II_ID="weewx-webroot"
II_TITLE="WeeWX as default web root"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="webserver"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_EDITABLE_CONFIG="WEEWX_WEB_DIR"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh
source lib/verify.sh

FILE_CONFIG_WEEWX="${PATH_CONFIG:-config}/weewx.config"
[[ -f $FILE_CONFIG_WEEWX ]] && source "$FILE_CONFIG_WEEWX"
state_apply_menu_overrides
WEEWX_WEB_DIR="${WEEWX_WEB_DIR:-/var/www/html/weewx}"

NGINX_SITE="/etc/nginx/sites-available/default"
APACHE_SITE="/etc/apache2/sites-available/000-default.conf"
LIGHTTPD_CONF="/etc/lighttpd/lighttpd.conf"
CADDYFILE="/etc/caddy/Caddyfile"

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

# detect_active_backend
# Walks the four backend ids in the same order as the webserver feature's
# II_OPTIONAL_GROUP and echoes the first one whose status registry says it's
# completed. Echoes nothing if none is installed (caller should bail).
detect_active_backend() {
  local b
  for b in nginx apache lighttpd caddy; do
    if [[ "$(status_state "$b" 2>/dev/null)" == "completed" ]]; then
      echo "$b"; return 0
    fi
  done
  return 1
}

# patch_root_in <file> <regex> <replacement>
# Idempotent sed-in-place: only rewrites if the regex matches AND the line
# isn't already equal to the replacement. Caller is responsible for taking
# a backup_create snapshot first.
patch_root_in() {
  local file="$1" regex="$2" repl="$3"
  if ! grep -qE "$regex" "$file" 2>/dev/null; then
    log_warn "Doc-root directive not found in $file (looked for: $regex). Leaving alone."
    return 1
  fi
  sudo sed -i -E "s|$regex|$repl|" "$file" \
    || { log_fail "sed failed on $file."; return 2; }
  return 0
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX"; then
    log_info "weewx-webroot already applied at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  local backend
  backend=$(detect_active_backend)
  if [[ -z $backend ]]; then
    log_fail "No active webserver backend found. Install nginx/apache/lighttpd/caddy first."
    status_mark_failed "$II_ID" "no active backend"
    echo -e "[ \e[0;31mFAIL\e[0m ] weewx-webroot needs an installed webserver backend."
    return 1
  fi
  log_info "Active backend: $backend. Repointing default site at $WEEWX_WEB_DIR."

  # Ensure the doc root exists (weewx + site-ramdisk also create it; do it
  # here too so a standalone weewx-webroot install passes the backend's
  # post-write reload-test without depending on install order).
  if [[ ! -d $WEEWX_WEB_DIR ]]; then
    sudo mkdir -p "$WEEWX_WEB_DIR" \
      || { status_mark_failed "$II_ID" "mkdir $WEEWX_WEB_DIR failed"; return 1; }
  fi

  local target test_cmd reload_unit
  case "$backend" in
    nginx)
      target="$NGINX_SITE"
      test_cmd="sudo nginx -t"
      reload_unit="nginx"
      ;;
    apache)
      target="$APACHE_SITE"
      test_cmd="sudo apache2ctl configtest"
      reload_unit="apache2"
      ;;
    lighttpd)
      target="$LIGHTTPD_CONF"
      test_cmd="sudo lighttpd -t -f $LIGHTTPD_CONF"
      reload_unit="lighttpd"
      ;;
    caddy)
      target="$CADDYFILE"
      test_cmd="sudo caddy validate --config $CADDYFILE --adapter caddyfile"
      reload_unit="caddy"
      ;;
  esac

  if [[ ! -f $target ]]; then
    log_fail "Expected backend config at $target — not present."
    status_mark_failed "$II_ID" "config missing"
    return 1
  fi

  # Snapshot before any edit (once, idempotent across re-runs).
  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up $target."
    backup_create "$II_ID" "$target" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  # Each backend has its own root-directive shape; we patch in place rather
  # than rewriting the whole file so SSL/HTTP-policy edits written earlier
  # by webserver-ssl / feature-caddy stay intact. replace_all-style sed is
  # used for caddy because its Caddyfile contains the directive in multiple
  # site blocks (named site + :443 catch-all).
  case "$backend" in
    nginx)
      patch_root_in "$target" \
        '^([[:space:]]*)root[[:space:]]+[^;]+;' \
        "\\1root ${WEEWX_WEB_DIR};" \
        || { status_mark_failed "$II_ID" "nginx root patch failed"; return 1; }
      ;;
    apache)
      patch_root_in "$target" \
        '^([[:space:]]*)DocumentRoot[[:space:]]+[^[:space:]]+' \
        "\\1DocumentRoot ${WEEWX_WEB_DIR}" \
        || { status_mark_failed "$II_ID" "apache DocumentRoot patch failed"; return 1; }
      ;;
    lighttpd)
      patch_root_in "$target" \
        '^([[:space:]]*server\.document-root[[:space:]]*=[[:space:]]*)"[^"]+"' \
        "\\1\"${WEEWX_WEB_DIR}\"" \
        || { status_mark_failed "$II_ID" "lighttpd document-root patch failed"; return 1; }
      ;;
    caddy)
      patch_root_in "$target" \
        '^([[:space:]]*)root[[:space:]]+\*[[:space:]]+[^[:space:]]+' \
        "\\1root * ${WEEWX_WEB_DIR}" \
        || { status_mark_failed "$II_ID" "caddy root patch failed"; return 1; }
      ;;
  esac

  log_info "Testing ${backend} config."
  if ! $test_cmd 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
    log_fail "${backend} config test failed; restoring pre-install snapshot."
    backup_restore_or_remove "$II_ID" "$target" || log_warn "restore failed."
    status_mark_failed "$II_ID" "${backend} config test failed"
    return 1
  fi

  log_info "Reloading ${reload_unit}."
  if ! sudo systemctl reload "$reload_unit" 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
    # Reload can fail if the service was never started (e.g. apt failed earlier);
    # try a start instead.
    sudo systemctl restart "$reload_unit" \
      || log_warn "${reload_unit} reload/restart failed; check the service manually."
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX"
  log_ok "weewx-webroot applied for backend ${backend}."
  echo -e "[  \e[0;32mOK\e[0m  ] WeeWX is now the default web root (${backend} -> ${WEEWX_WEB_DIR})."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "weewx-webroot already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] weewx-webroot is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record for weewx-webroot; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # Restore whichever backend's config we snapshotted; backup_restore_or_remove
  # works on the union of files in the snapshot so we don't need to remember
  # which backend was active at install time.
  local snap_files
  snap_files=$(backup_latest "$II_ID")
  if [[ -n $snap_files ]]; then
    local backend
    backend=$(detect_active_backend)
    local target=""
    case "$backend" in
      nginx)    target="$NGINX_SITE"    ;;
      apache)   target="$APACHE_SITE"   ;;
      lighttpd) target="$LIGHTTPD_CONF" ;;
      caddy)    target="$CADDYFILE"     ;;
    esac
    if [[ -n $target ]]; then
      log_info "Restoring $target from snapshot."
      backup_restore_or_remove "$II_ID" "$target" || log_warn "restore returned non-zero."
      sudo systemctl reload "${backend/apache/apache2}" 2>/dev/null || true
    fi
  fi

  status_mark_uninstalled "$II_ID"
  log_ok "weewx-webroot uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] weewx-webroot uninstalled (original default site restored)."
  return 0
}

do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_file_exists "${WEEWX_WEB_DIR:-/var/www/html/weewx}" 2>&1); then echo "$err"; rc=1; fi
  return $rc
}

if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "verify" ]]; then
  do_verify
else
  do_uninstall
fi
exit $?
