#!/bin/bash

# Module:      Database — MySQL (hidden child of feature-database)
# Description: Installs mysql-server when DATABASE_HOST=SELF (or empty),
#              provisions the WeeWX DB + user via root socket auth,
#              installs the role-specific Python bindings, and writes
#              /etc/installicious/state/database.state. When
#              DATABASE_HOST is a remote IP, skips the server install +
#              provisioning and just installs Python bindings.
#
#              Thin shell — all logic in lib/database.sh.
#
#              Note on mysql-server availability: Debian Bookworm /
#              Trixie ship the `default-mysql-server` virtual package
#              that resolves to mariadb-server. For a TRUE Oracle MySQL
#              install you'd add the Oracle repo separately; on
#              Bookworm/Trixie out of the box, picking "mysql" via this
#              feature gets you mariadb-server under the hood. The
#              feature is preserved as a separate child so future
#              installs from Oracle's repo can land cleanly without
#              breaking the menu shape.

# === II_MANIFEST_BEGIN ===
II_ID="database-mysql"
II_TITLE="MySQL"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_APT_PACKAGES="default-mysql-server"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/installer_apt.sh
source lib/database.sh
source lib/verify.sh

FILE_CONFIG_DB="${PATH_CONFIG:-config}/database.config"
[[ -f $FILE_CONFIG_DB ]] && source "$FILE_CONFIG_DB"
state_apply_menu_overrides

SERVICE="mariadb"   # default-mysql-server pulls mariadb-server on Bookworm/Trixie

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

do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err

  # Skip server check if remote (we don't run it locally).
  if [[ "${DATABASE_HOST:-SELF}" =~ ^(SELF|self|localhost|127\.0\.0\.1|)$ ]]; then
    if ! err=$(verify_dpkg_installed default-mysql-server 2>&1); then echo "$err"; rc=1; fi
    if ! err=$(verify_systemd_active "$SERVICE" 2>&1); then echo "$err"; rc=1; fi
    # Trivial liveness query through socket auth.
    if ! sudo -n mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
      echo "mysql -u root socket-auth SELECT 1 failed (server up but root socket auth broken)"
      rc=1
    fi
  else
    echo "remote DATABASE_HOST=$DATABASE_HOST — skipped local server checks"
  fi

  if ! err=$(verify_dpkg_installed python3-pymysql 2>&1); then echo "$err"; rc=1; fi
  return $rc
}
if [[ $MODE == "verify" ]]; then do_verify; exit $?; fi

if [[ $MODE == "install" ]]; then
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_DB"; then
    log_info "database-mysql already installed at recorded version + config. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"

  if database_install_mysql_family "$II_ID" "$II_APT_PACKAGES" "mysql" "$SERVICE" "$STATUS_FILE"; then
    status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_DB"
    log_ok "database-mysql installed."
    echo -e "[  \e[0;32mOK\e[0m  ] Database backend: MySQL (mariadb-server backed on Debian)."
    exit 0
  fi
  exit 1
fi

# --uninstall
case "$(status_state "$II_ID")" in
  uninstalled)
    log_info "database-mysql already uninstalled."
    echo -e "[  \e[0;32mOK\e[0m  ] database-mysql is already uninstalled."
    exit 0
    ;;
  "")
    log_warn "No install record for database-mysql; nothing to revert."
    status_mark_uninstalled "$II_ID"
    exit 0
    ;;
esac

# Resolve creds from current config + database.creds so uninstall knows
# which user/db to drop. Don't fail if AUTO is unresolvable — fall back
# to documented defaults.
database_load_role_sidecar "$(database_active_role)"
: "${DATABASE_NAME:=AUTO}"
: "${DATABASE_USER:=AUTO}"
[[ "$DATABASE_NAME" == "AUTO" ]] && DATABASE_NAME="${DATABASE_DEFAULT_NAME:-weewx}"
[[ "$DATABASE_USER" == "AUTO" ]] && DATABASE_USER="$DATABASE_NAME"

database_uninstall_mysql_family "$II_ID" "$II_APT_PACKAGES" "mysql" "$SERVICE" "$STATUS_FILE"
status_mark_uninstalled "$II_ID"
log_ok "database-mysql uninstalled."
echo -e "[  \e[0;32mOK\e[0m  ] database-mysql uninstalled (server + DB + user dropped)."
exit 0
