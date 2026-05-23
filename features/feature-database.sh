#!/bin/bash

# Module:      Database (parent grouping feature)
# Description: Pure grouping shell. Selecting "database" triggers a
#              single-select sub-menu (II_OPTIONAL_GROUP_MODE="exclusive")
#              where the user picks ONE of sqlite / mysql / mariadb.
#              The chosen child writes /etc/installicious/state/database.state
#              so downstream features (feature-weewx-setup, the WeeWX
#              backup runtime script, etc.) can read DATABASE_TYPE and
#              wire WeeWX (or any future role's consumer) at install
#              time.
#
#              Five editable keys live on this parent (II_EDITABLE_CONFIG):
#                  DATABASE_HOST       SELF | <IP>
#                  DATABASE_NAME       AUTO | <name>
#                  DATABASE_USER       AUTO | <user>
#                  DATABASE_PASS       AUTO | <password>
#                  DATABASE_INNODB_TUNE off  | on
#              All five are HIDDEN on the Edit Configuration screen when
#              the picked child is database-sqlite (none of them apply to
#              SQLite). The gating is implemented by _applies_DATABASE_*
#              helpers in feature-database.choices.sh.
#
#              The body is intentionally a no-op apart from status
#              bookkeeping — all real install work happens in the chosen
#              child feature.

# === II_MANIFEST_BEGIN ===
II_ID="database"
II_TITLE="Database"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="DATABASE_HOST DATABASE_NAME DATABASE_USER DATABASE_PASS DATABASE_INNODB_TUNE"
II_OPTIONAL_GROUP="database-sqlite database-mysql database-mariadb"
II_OPTIONAL_GROUP_MODE="exclusive"
II_RESTRICT_TO_ROLES=""
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh

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

if [[ $MODE == "install" ]]; then
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "Database (parent) already recorded at version $II_VERSION. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"
  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "Database parent recorded; backend (sqlite/mysql/mariadb) handles install."
  exit 0
fi

# --uninstall: nothing to revert here; the chosen backend's own
# --uninstall reverts apt + config + state. Mark uninstalled so
# re-running install is not blocked by a stale 'completed' record.
status_mark_uninstalled "$II_ID"
log_ok "Database parent record cleared."
exit 0
