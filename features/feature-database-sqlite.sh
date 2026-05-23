#!/bin/bash

# Module:      Database — SQLite (hidden child of feature-database)
# Description: No-op leaf. The weewx apt package ships with SQLite as
#              its default backend, so picking this means "do nothing
#              extra." The body writes /etc/installicious/state/database.state
#              with DATABASE_TYPE="sqlite" so downstream consumers
#              (feature-weewx-setup, the WeeWX backup runtime, etc.)
#              can see a uniform DATABASE_TYPE value.
#
#              Hidden behind II_RESTRICT_TO_ROLES — only visible via
#              the parent feature-database's radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="database-sqlite"
II_TITLE="SQLite (default)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_RESTRICT_TO_ROLES="weewx"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh

DATABASE_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/database.state"
DATABASE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/database.creds"

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
    log_info "database-sqlite already recorded at version $II_VERSION. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"

  log_info "Writing $DATABASE_STATE_FILE (DATABASE_TYPE=sqlite)."
  sudo mkdir -p "$(dirname "$DATABASE_STATE_FILE")"
  sudo tee "$DATABASE_STATE_FILE" >/dev/null <<'STATE'
# /etc/installicious/state/database.state — written by feature-database-sqlite.
# Downstream consumers source this to learn the active DB backend.
DATABASE_TYPE="sqlite"
DATABASE_HOST=""
DATABASE_NAME=""
DATABASE_USER=""
DATABASE_PORT=""
STATE
  sudo chmod 0644 "$DATABASE_STATE_FILE"

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "database-sqlite recorded — WeeWX will use its default SQLite backend."
  echo -e "[  \e[0;32mOK\e[0m  ] Database backend: SQLite (default)."
  exit 0
fi

# --uninstall — remove the state file so a subsequent run starts fresh.
# Leave the creds file (no SQLite secrets stored) and the actual weewx
# SQLite DB alone — that is WeeWX's data, not ours to delete.
log_info "Removing $DATABASE_STATE_FILE."
sudo rm -f "$DATABASE_STATE_FILE"
status_mark_uninstalled "$II_ID"
log_ok "database-sqlite uninstalled (state cleared)."
exit 0
