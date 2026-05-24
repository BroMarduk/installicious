#!/bin/bash

# lib/database.sh — shared install/uninstall/provisioning helpers for
# the feature-database-mysql / feature-database-mariadb children.
#
# Both children are thin shells that source this lib and call:
#   database_install_mysql_family "$II_ID" "$II_APT_PACKAGES" "$DB_TYPE"
#       "$SERVICE" "$STATUS_FILE"
#   database_uninstall_mysql_family ... (same args)
#
# Where DB_TYPE is "mysql" or "mariadb" and SERVICE is the systemd unit
# (e.g. "mariadb" or "mysql"). The children supply only the differences
# (package list + service name); the rest is shared.
#
# This lib expects the caller to have already sourced:
#   lib/log.sh lib/status.sh lib/state.sh lib/apt.sh lib/installer_apt.sh
#   config/installicious.config
# and to have done log_init + status_mark_started.

DATABASE_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/database.state"
DATABASE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/database.creds"

# database_load_role_sidecar — source ${PATH_CONFIG}/database-${role}.config
# if present. Caller sets LAST_ROLE_ID (read from selections.sh).
database_load_role_sidecar() {
  local role="$1"
  [[ -z $role ]] && return 0
  local f="${PATH_CONFIG:-config}/database-${role}.config"
  if [[ -f $f ]]; then
    # shellcheck disable=SC1090
    source "$f"
    log_info "Sourced per-role sidecar: $f"
  fi
}

# database_active_role — echo LAST_ROLE_ID from the picker selections
# file, or empty if unknown.
database_active_role() {
  local sfile="${PATH_STATE:-state}/selections.sh"
  [[ -f $sfile ]] || return 0
  ( # shellcheck disable=SC1090
    source "$sfile" 2>/dev/null
    printf '%s' "${LAST_ROLE_ID:-}"
  )
}

# database_is_local — rc=0 if DATABASE_HOST is SELF / empty / localhost,
# rc=1 otherwise (remote).
database_is_local() {
  case "${DATABASE_HOST:-SELF}" in
    SELF|self|localhost|127.0.0.1|"") return 0 ;;
    *) return 1 ;;
  esac
}

# database_generate_password — print a 24-char alnum password to stdout.
database_generate_password() {
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24
}

# database_persist_password "<pw>" — write DATABASE_PASS=<pw> to
# /etc/installicious/state/database.creds (mode 0600, root-owned).
# Uses sudo only when the target directory is not already user-writable
# (production: /etc/installicious; tests: tempdir owned by current user).
database_persist_password() {
  local pw="$1" dir
  dir="$(dirname "$DATABASE_CREDS_FILE")"
  if [[ -w "$dir" ]] || mkdir -p "$dir" 2>/dev/null; then
    mkdir -p "$dir" 2>/dev/null || true
    printf 'DATABASE_PASS="%s"\n' "$pw" > "$DATABASE_CREDS_FILE"
    chmod 0600 "$DATABASE_CREDS_FILE" 2>/dev/null || true
  else
    sudo mkdir -p "$dir"
    printf 'DATABASE_PASS="%s"\n' "$pw" | sudo tee "$DATABASE_CREDS_FILE" >/dev/null
    sudo chmod 0600 "$DATABASE_CREDS_FILE"
    sudo chown root:root "$DATABASE_CREDS_FILE" 2>/dev/null || true
  fi
}

# database_load_persisted_password — echo the stored DATABASE_PASS from
# database.creds (or empty if no file / no value).
database_load_persisted_password() {
  [[ -f $DATABASE_CREDS_FILE ]] || return 0
  ( # shellcheck disable=SC1090
    source "$DATABASE_CREDS_FILE" 2>/dev/null
    printf '%s' "${DATABASE_PASS:-}"
  )
}

# database_resolve_credentials — turn AUTO sentinels into concrete values.
# Reads the globals DATABASE_NAME / DATABASE_USER / DATABASE_PASS;
# overwrites them in place. Requires DATABASE_DEFAULT_NAME (from the
# per-role sidecar) for AUTO name resolution, fallback "weewx".
#
# Returns rc=0 on success, rc=1 if remote-DB + AUTO creds (caller
# should fail with the documented error message).
database_resolve_credentials() {
  local default_name="${DATABASE_DEFAULT_NAME:-weewx}"

  if ! database_is_local; then
    # Remote DB — AUTO USER or PASS is a hard error.
    if [[ "${DATABASE_USER:-AUTO}" == "AUTO" || "${DATABASE_PASS:-AUTO}" == "AUTO" ]]; then
      return 1
    fi
    # DATABASE_NAME=AUTO is fine for remote; default it here.
    [[ "${DATABASE_NAME:-AUTO}" == "AUTO" ]] && DATABASE_NAME="$default_name"
    return 0
  fi

  # Local DB — AUTO resolves as documented.
  [[ "${DATABASE_NAME:-AUTO}" == "AUTO" ]] && DATABASE_NAME="$default_name"
  [[ "${DATABASE_USER:-AUTO}" == "AUTO" ]] && DATABASE_USER="$DATABASE_NAME"
  if [[ "${DATABASE_PASS:-AUTO}" == "AUTO" ]]; then
    local stored; stored=$(database_load_persisted_password)
    if [[ -n $stored ]]; then
      DATABASE_PASS="$stored"
      log_info "Reusing persisted password from $DATABASE_CREDS_FILE."
    else
      DATABASE_PASS=$(database_generate_password)
      database_persist_password "$DATABASE_PASS"
      log_info "Generated new password and persisted to $DATABASE_CREDS_FILE."
    fi
  fi
  return 0
}

# database_provision_local — CREATE DATABASE/USER/GRANT via root socket
# auth on a fresh Debian mariadb-server/mysql-server install. Idempotent
# (IF NOT EXISTS). Returns rc=0 on success, rc=2 if socket auth is
# unavailable (caller should fail with a clear pointer to the manual
# provisioning path).
database_provision_local() {
  local sql
  sql=$(printf '%s\n' \
    "CREATE DATABASE IF NOT EXISTS \`${DATABASE_NAME}\`;" \
    "CREATE USER IF NOT EXISTS '${DATABASE_USER}'@'localhost' IDENTIFIED BY '${DATABASE_PASS}';" \
    "ALTER USER '${DATABASE_USER}'@'localhost' IDENTIFIED BY '${DATABASE_PASS}';" \
    "GRANT ALL PRIVILEGES ON \`${DATABASE_NAME}\`.* TO '${DATABASE_USER}'@'localhost';" \
    "FLUSH PRIVILEGES;")
  log_info "Provisioning database \`${DATABASE_NAME}\` and user '${DATABASE_USER}'@'localhost' (idempotent CREATE IF NOT EXISTS)."
  # Capture mysql's exit code and output separately, then tee the output.
  # `if ! cmd | tee ...` would test tee's exit (~always 0), masking a real
  # mysql failure and silently returning success here.
  local out rc
  out=$(sudo mysql -u root <<< "$sql" 2>&1); rc=$?
  [[ -n $out ]] && printf '%s\n' "$out" | tee -a "$FILE_LOG_INSTALLER" >/dev/null
  if [[ $rc -ne 0 ]]; then
    log_fail "Root socket auth into mysql/mariadb failed."
    return 2
  fi
  return 0
}

# database_install_python_bindings — install the role-specific Python
# packages for the picked DB type. Reads DATABASE_<TYPE>_PYTHON_PACKAGES
# from the per-role sidecar (set by database_load_role_sidecar above).
# Empty list is a no-op (SQLite case).
database_install_python_bindings() {
  local db_type="$1" status_file="$2" varname pkgs
  # ${db_type^^} = uppercase via Bash 4 parameter expansion (no fork).
  # ${!varname} = indirect expansion -- read the variable whose NAME is
  # held in $varname (e.g. DATABASE_MYSQL_PYTHON_PACKAGES). The per-role
  # sidecar (config/database-<role>.config) sets these.
  varname="DATABASE_${db_type^^}_PYTHON_PACKAGES"
  pkgs="${!varname:-}"
  if [[ -z $pkgs ]]; then
    log_info "No Python bindings configured for DB type '$db_type' under role '$(database_active_role)' — skipping."
    return 0
  fi
  log_info "Installing Python bindings for '$db_type': $pkgs"
  # shellcheck disable=SC2086
  installer_apt_record_install "$status_file" $pkgs
}

# database_write_state_file — emit /etc/installicious/state/database.state
# with the resolved (post-AUTO) values for downstream consumers.
database_write_state_file() {
  local db_type="$1"
  log_info "Writing $DATABASE_STATE_FILE."
  sudo mkdir -p "$(dirname "$DATABASE_STATE_FILE")"
  sudo tee "$DATABASE_STATE_FILE" >/dev/null <<STATE
# /etc/installicious/state/database.state — written by feature-database-${db_type}.
# Downstream consumers source this to learn the active DB backend.
DATABASE_TYPE="${db_type}"
DATABASE_HOST="${DATABASE_HOST}"
DATABASE_NAME="${DATABASE_NAME}"
DATABASE_USER="${DATABASE_USER}"
DATABASE_PORT="${DATABASE_PORT:-3306}"
STATE
  sudo chmod 0644 "$DATABASE_STATE_FILE"
}

# database_install_mysql_family <id> <apt_packages> <db_type> <service> <status_file>
# Top-level helper called by both feature-database-mysql and -mariadb.
database_install_mysql_family() {
  local id="$1" apt_packages="$2" db_type="$3" service="$4" status_file="$5"
  local role rc

  role=$(database_active_role)
  database_load_role_sidecar "$role"

  # Defaults if config files left things unset.
  : "${DATABASE_HOST:=SELF}"
  : "${DATABASE_NAME:=AUTO}"
  : "${DATABASE_USER:=AUTO}"
  : "${DATABASE_PASS:=AUTO}"
  : "${DATABASE_PORT:=3306}"

  database_resolve_credentials
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log_fail "DATABASE_HOST=${DATABASE_HOST} is remote but DATABASE_USER or DATABASE_PASS is AUTO."
    status_mark_failed "$id" "remote DB requires explicit USER + PASS"
    echo -e "[ \e[0;31mFAIL\e[0m ] Remote DATABASE_HOST requires explicit DATABASE_USER and DATABASE_PASS (cannot create a user on a database we do not own). Set both via the in-menu editor or overrides/configuration.override."
    return 1
  fi

  if database_is_local; then
    # Install the server.
    log_info "Installing local DB server: $apt_packages"
    # shellcheck disable=SC2086
    installer_apt_record_install "$status_file" $apt_packages
    rc=$?
    if [[ $rc -ne 0 ]]; then
      status_mark_failed "$id" "apt install failed (code $rc)"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install $apt_packages. Error Code: $rc."
      return $rc
    fi

    log_info "Enabling + starting $service."
    sudo systemctl enable --now "$service" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
      || log_warn "enable $service returned non-zero."

    if ! database_provision_local; then
      status_mark_failed "$id" "provisioning failed (root socket auth)"
      echo -e "[ \e[0;31mFAIL\e[0m ] Could not provision via 'sudo mysql -u root'. Re-enable socket auth (ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;) or provision the WeeWX DB + user by hand and re-run."
      return 1
    fi
    database_apply_innodb_tune "$service"
  else
    log_info "DATABASE_HOST=${DATABASE_HOST} — remote DB; skipping server install + provisioning."
  fi

  database_install_python_bindings "$db_type" "$status_file"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$id" "Python bindings install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Python bindings. Error Code: $rc."
    return $rc
  fi

  database_write_state_file "$db_type"
  return 0
}

# database_uninstall_mysql_family <id> <apt_packages> <db_type> <service> <status_file>
# Reverses install. Drops the WeeWX DB + user IF we created them, removes
# the InnoDB tuning drop-in (Phase 4 lands the write side), removes
# state + creds files.
database_uninstall_mysql_family() {
  local id="$1" apt_packages="$2" db_type="$3" service="$4" status_file="$5"

  if database_is_local && systemctl is-active --quiet "$service" 2>/dev/null; then
    log_info "Dropping database \`${DATABASE_NAME:-weewx}\` and user '${DATABASE_USER:-weewx}'@'localhost' — DATA WILL BE DESTROYED."
    local sql
    sql=$(printf '%s\n' \
      "DROP DATABASE IF EXISTS \`${DATABASE_NAME:-weewx}\`;" \
      "DROP USER IF EXISTS '${DATABASE_USER:-weewx}'@'localhost';" \
      "FLUSH PRIVILEGES;")
    # Same exit-code-vs-tee separation as database_provision_local: `cmd |
    # tee || ...` would only fire log_warn on tee failure, never on a real
    # mysql error.
    local drop_out drop_rc
    drop_out=$(sudo mysql -u root <<< "$sql" 2>&1); drop_rc=$?
    [[ -n $drop_out ]] && printf '%s\n' "$drop_out" | tee -a "$FILE_LOG_INSTALLER" >/dev/null
    [[ $drop_rc -ne 0 ]] && log_warn "DROP DATABASE/USER returned non-zero (continuing uninstall)."

    log_info "Stopping $service."
    sudo systemctl stop "$service" 2>/dev/null || true
  fi

  # InnoDB tuning drop-in: removed unconditionally if present (Phase 4
  # is the writer; uninstall here is forward-compatible).
  if [[ -f /etc/mysql/conf.d/installicious-pi.cnf ]]; then
    log_info "Removing /etc/mysql/conf.d/installicious-pi.cnf."
    sudo rm -f /etc/mysql/conf.d/installicious-pi.cnf
  fi

  # shellcheck disable=SC2086
  installer_apt_revert "$status_file" $apt_packages

  log_info "Removing state files."
  sudo rm -f "$DATABASE_STATE_FILE" "$DATABASE_CREDS_FILE"
  return 0
}

# database_apply_innodb_tune <service>
# When DATABASE_INNODB_TUNE=on AND we're local, write the drop-in and
# restart. When DATABASE_INNODB_TUNE=off AND the drop-in exists, remove
# it and restart (self-healing on flip-off).
database_apply_innodb_tune() {
  local service="$1"
  local conf="/etc/mysql/conf.d/installicious-pi.cnf"

  if ! database_is_local; then
    log_info "Skipping InnoDB tune — DATABASE_HOST=${DATABASE_HOST} is remote."
    return 0
  fi

  if [[ "${DATABASE_INNODB_TUNE:-off}" != "on" ]]; then
    if [[ -f $conf ]]; then
      log_info "DATABASE_INNODB_TUNE=off but $conf exists — removing and restarting $service."
      sudo rm -f "$conf"
      sudo systemctl restart "$service" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
        || log_warn "restart $service after tune-off returned non-zero."
    fi
    return 0
  fi

  source lib/pi-tier.sh
  local pool_size flush
  flush="${DATABASE_INNODB_FLUSH_LOG_AT_TRX_COMMIT:-2}"
  if [[ "${DATABASE_INNODB_BUFFER_POOL_SIZE:-AUTO}" == "AUTO" ]]; then
    pool_size=$(pi_tier_size_for "64M 128M 256M 512M")
  else
    pool_size="$DATABASE_INNODB_BUFFER_POOL_SIZE"
  fi

  log_info "Writing $conf (innodb_flush_log_at_trx_commit=$flush, innodb_buffer_pool_size=$pool_size)."
  sudo tee "$conf" >/dev/null <<CONF
# /etc/mysql/conf.d/installicious-pi.cnf
# Generated by feature-database-mysql / -mariadb when DATABASE_INNODB_TUNE=on.
# Delete this file (or set DATABASE_INNODB_TUNE=off and re-run installicious)
# and restart the server to revert.
[mysqld]
# Flush the InnoDB redo log to disk once per second instead of on every
# commit -- big SD-write reduction. Up to ~1 sec of just-committed
# transactions can be lost on power loss; for a WeeWX station with 5-min
# archive intervals that's a non-issue.
innodb_flush_log_at_trx_commit = ${flush}

# Cache more table data + indexes in RAM, fewer SD reads. Auto-sized
# per Pi RAM tier; override via DATABASE_INNODB_BUFFER_POOL_SIZE in
# configuration.override.
innodb_buffer_pool_size = ${pool_size}
CONF
  sudo chmod 0644 "$conf"

  log_info "Restarting $service to apply tune."
  sudo systemctl restart "$service" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
    || log_warn "restart $service returned non-zero."
}
