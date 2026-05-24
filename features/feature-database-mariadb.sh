#!/bin/bash

# Module:      Database — MariaDB (hidden child of feature-database)
# Description: Installs mariadb-server when DATABASE_HOST=SELF (or empty),
#              provisions the WeeWX DB + user via root socket auth,
#              installs the role-specific Python bindings, and writes
#              /etc/installicious/state/database.state. When
#              DATABASE_HOST is a remote IP, skips the server install +
#              provisioning and just installs Python bindings.
#
#              Thin shell — all logic in lib/database.sh.
#
#              Installs mariadb-server directly (the Debian-shipped
#              package; no extra repo needed).

# === II_MANIFEST_BEGIN ===
II_ID="database-mariadb"
II_TITLE="MariaDB"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_APT_PACKAGES="mariadb-server"
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

SERVICE="mariadb"   # systemd unit shipped by the mariadb-server package

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

  if [[ "${DATABASE_HOST:-SELF}" =~ ^(SELF|self|localhost|127\.0\.0\.1|)$ ]]; then
    if ! err=$(verify_dpkg_installed mariadb-server 2>&1); then echo "$err"; rc=1; fi
    if ! err=$(verify_systemd_active "$SERVICE" 2>&1); then echo "$err"; rc=1; fi
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
    log_info "database-mariadb already installed at recorded version + config. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"

  if database_install_mysql_family "$II_ID" "$II_APT_PACKAGES" "mariadb" "$SERVICE" "$STATUS_FILE"; then
    status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_DB"
    log_ok "database-mariadb installed."
    echo -e "[  \e[0;32mOK\e[0m  ] Database backend: MariaDB."
    exit 0
  fi
  exit 1
fi

# --uninstall
case "$(status_state "$II_ID")" in
  uninstalled)
    log_info "database-mariadb already uninstalled."
    echo -e "[  \e[0;32mOK\e[0m  ] database-mariadb is already uninstalled."
    exit 0
    ;;
  "")
    log_warn "No install record for database-mariadb; nothing to revert."
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

database_uninstall_mysql_family "$II_ID" "$II_APT_PACKAGES" "mariadb" "$SERVICE" "$STATUS_FILE"
status_mark_uninstalled "$II_ID"
log_ok "database-mariadb uninstalled."
echo -e "[  \e[0;32mOK\e[0m  ] database-mariadb uninstalled (server + DB + user dropped)."
exit 0
