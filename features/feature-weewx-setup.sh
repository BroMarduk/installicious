#!/bin/bash

# Module:      WeeWX station setup
# Description: Configures the WeeWX install non-interactively so the apt
#              package never has to prompt, then applies the user's
#              optional weewx.conf overrides.
#
#              Two-layer config:
#                1. Install-critical, per-Pi-unique settings — station
#                   location, lat/lon, altitude, units, driver, registry
#                   opt-in — live as WEEWX_STATION_* keys in
#                   config/weewx.config and surface on the in-menu Edit
#                   Configuration screen. They're fed to weewx's own
#                   reconfigure CLI (`weectl station reconfigure` on
#                   weewx 5, `wee_config --reconfigure` on weewx 4) so
#                   weewx parses + rewrites weewx.conf itself.
#                2. Everything else — report skins, RESTful uploaders,
#                   logging, retention, driver-specific sections — lives
#                   in overrides/weewx.conf, a partial weewx.conf the
#                   user edits with a text editor. After the reconfigure
#                   pass, resources/weewx-merge-overrides.py deep-merges
#                   that file onto /etc/weewx/weewx.conf via configobj
#                   (a weewx dependency, so it's always present).
#
#              II_DEPS="weewx": the apt package (packages/package-weewx.sh)
#              installs first. weewx's debconf install is already silent
#              under DEBIAN_FRONTEND=noninteractive (set in lib/apt.sh's
#              _APT_ENV); this feature does the post-install config pass.
#
#              Local-MySQL/MariaDB schema sanity: when DATABASE_TYPE is
#              mysql or mariadb AND the server is local, this feature
#              waits up to 30s for mariadb's root-socket to respond,
#              then queries the live `archive` table row count. Empty or
#              missing → DROP + CREATE the database so weewx initializes
#              the schema cleanly on its next start. Any rows → leave the
#              data alone. Works around weewx 5's _initialize_day_tables
#              emitting bare `CREATE TABLE` (no IF NOT EXISTS), which
#              crashes on the next start if a prior install left even a
#              fully-built schema in place across a reboot.
#
#              Symmetric --uninstall: restores /etc/weewx/weewx.conf from
#              the pre-install snapshot via lib/backup.

# === II_MANIFEST_BEGIN ===
II_ID="weewx-setup"
II_TITLE="WeeWX station setup (non-interactive config)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="weewx database"
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_EDITABLE_CONFIG="WEEWX_STATION_LOCATION WEEWX_LATITUDE WEEWX_LONGITUDE WEEWX_ALTITUDE WEEWX_ALTITUDE_UNITS WEEWX_STATION_TYPE WEEWX_UNITS WEEWX_REGISTER_STATION WEEWX_STATION_URL"
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
WEEWX_STATION_LOCATION="${WEEWX_STATION_LOCATION:-}"
WEEWX_LATITUDE="${WEEWX_LATITUDE:-}"
WEEWX_LONGITUDE="${WEEWX_LONGITUDE:-}"
WEEWX_ALTITUDE="${WEEWX_ALTITUDE:-}"
WEEWX_ALTITUDE_UNITS="${WEEWX_ALTITUDE_UNITS:-foot}"
WEEWX_STATION_TYPE="${WEEWX_STATION_TYPE:-Simulator}"
WEEWX_UNITS="${WEEWX_UNITS:-us}"
WEEWX_REGISTER_STATION="${WEEWX_REGISTER_STATION:-false}"
WEEWX_STATION_URL="${WEEWX_STATION_URL:-}"

WEEWX_CONF="/etc/weewx/weewx.conf"
# overrides/weewx.conf is the git-tracked default template. A sibling
# weewx.override — if present — is the user's personal copy (gitignored
# via the *.override rule) and takes precedence, so personal
# customizations and secrets stay out of git while the shipped template
# stays clean.
OVERRIDE_FILE="${PATH_OVERRIDES:-overrides}/weewx.conf"
_personal_override="${OVERRIDE_FILE%.conf}.override"
[[ -f "$_personal_override" ]] && OVERRIDE_FILE="$_personal_override"
MERGE_HELPER="${PATH_RESOURCES:-resources}/weewx-merge-overrides.py"

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

# _driver_module <station-type> -> echo the weewx driver module path for a
# friendly station-type name, or empty if unknown. weewx's reconfigure CLI
# wants the module path (weewx.drivers.vantage), not the friendly label.
# An unknown type means we skip the --driver flag and leave whatever the
# package default is (Simulator) — the user then sets the real driver via
# overrides/weewx.conf or a manual `weectl station reconfigure` run.
_driver_module() {
  case "${1,,}" in
    simulator)      echo "weewx.drivers.simulator" ;;
    vantage)        echo "weewx.drivers.vantage" ;;
    acurite)        echo "weewx.drivers.acurite" ;;
    fineoffsetusb)  echo "weewx.drivers.fousb" ;;
    te923)          echo "weewx.drivers.te923" ;;
    ultimeter)      echo "weewx.drivers.ultimeter" ;;
    wmr100)         echo "weewx.drivers.wmr100" ;;
    wmr300)         echo "weewx.drivers.wmr300" ;;
    wmr9x8)         echo "weewx.drivers.wmr9x8" ;;
    ws1)            echo "weewx.drivers.ws1" ;;
    ws23xx)         echo "weewx.drivers.ws23xx" ;;
    ws28xx)         echo "weewx.drivers.ws28xx" ;;
    *)              echo "" ;;
  esac
}

# run_reconfigure — drives weewx's own config CLI with the WEEWX_STATION_*
# values. Detects weewx 5 (weectl) vs weewx 4 (wee_config) and only passes
# flags for non-empty config values, so a blank field leaves weewx's
# package default untouched. Returns non-zero if the CLI call fails.
run_reconfigure() {
  local -a args=()
  [[ -n $WEEWX_STATION_LOCATION ]] && args+=(--location="$WEEWX_STATION_LOCATION")
  [[ -n $WEEWX_LATITUDE ]]         && args+=(--latitude="$WEEWX_LATITUDE")
  [[ -n $WEEWX_LONGITUDE ]]        && args+=(--longitude="$WEEWX_LONGITUDE")
  [[ -n $WEEWX_ALTITUDE ]]         && args+=(--altitude="${WEEWX_ALTITUDE},${WEEWX_ALTITUDE_UNITS}")
  [[ -n $WEEWX_UNITS ]]            && args+=(--units="$WEEWX_UNITS")

  local driver
  driver=$(_driver_module "$WEEWX_STATION_TYPE")
  if [[ -n $driver ]]; then
    args+=(--driver="$driver")
  else
    log_warn "Unknown station type '$WEEWX_STATION_TYPE' — skipping --driver. Set the driver via overrides/weewx.conf or 'weectl station reconfigure' by hand."
  fi

  if command -v weectl >/dev/null 2>&1; then
    # weewx 5: weectl station reconfigure. --register / --station-url are
    # weewx-5-only flags.
    if [[ ${WEEWX_REGISTER_STATION,,} == "true" ]]; then
      args+=(--register=y)
      [[ -n $WEEWX_STATION_URL ]] && args+=(--station-url="$WEEWX_STATION_URL")
    else
      args+=(--register=n)
    fi
    log_info "weewx 5 detected — weectl station reconfigure ${args[*]}"
    sudo weectl station reconfigure --no-prompt "${args[@]}" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
    return "${PIPESTATUS[0]}"
  elif command -v wee_config >/dev/null 2>&1; then
    # weewx 4: wee_config --reconfigure. No --register / --station-url —
    # those keys, if wanted, go through overrides/weewx.conf instead.
    if [[ ${WEEWX_REGISTER_STATION,,} == "true" ]]; then
      log_warn "weewx 4's wee_config has no --register flag — set [StdRESTful][[StationRegistry]] register_this_station=true in overrides/weewx.conf instead."
    fi
    log_info "weewx 4 detected — wee_config --reconfigure ${args[*]}"
    sudo wee_config --reconfigure --no-prompt "${args[@]}" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
    return "${PIPESTATUS[0]}"
  else
    log_warn "Neither weectl (weewx 5) nor wee_config (weewx 4) found — skipping the reconfigure pass. The override-file merge still runs."
    return 0
  fi
}

# apply_overrides — deep-merge overrides/weewx.conf onto /etc/weewx/weewx.conf
# via the Python configobj helper. A missing or all-comments override file
# is a no-op (the helper detects an empty parse and returns 0 without
# rewriting weewx.conf).
apply_overrides() {
  if [[ ! -f $OVERRIDE_FILE ]]; then
    log_info "No override file at $OVERRIDE_FILE; skipping the merge pass."
    return 0
  fi
  if [[ ! -f $MERGE_HELPER ]]; then
    log_fail "Merge helper missing at $MERGE_HELPER."
    return 1
  fi
  log_info "Merging $OVERRIDE_FILE onto $WEEWX_CONF."
  sudo python3 "$MERGE_HELPER" "$WEEWX_CONF" "$OVERRIDE_FILE" 2>&1 | tee -a "$FILE_LOG_INSTALLER"
  return "${PIPESTATUS[0]}"
}

do_install() {
  # Hash the shared weewx.config AND the resolved override file, so
  # editing overrides/weewx.override (or weewx.conf) re-triggers the
  # merge instead of being silently skipped.
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX" "$OVERRIDE_FILE"; then
    log_info "weewx-setup already applied at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  if [[ ! -f $WEEWX_CONF ]]; then
    log_fail "$WEEWX_CONF not found — the weewx apt package should have installed it."
    status_mark_failed "$II_ID" "weewx.conf missing"
    echo -e "[ \e[0;31mFAIL\e[0m ] weewx-setup: $WEEWX_CONF is missing (is the weewx package installed?)."
    return 1
  fi

  # Stop weewx so we're not rewriting the config out from under a running
  # instance. Remember whether it was active so we can restart it.
  local weewx_was_active=false
  if systemctl is-active --quiet weewx 2>/dev/null; then
    weewx_was_active=true
    log_info "Stopping weewx for the config pass."
    sudo systemctl stop weewx || log_warn "systemctl stop weewx returned non-zero."
  fi

  # Snapshot weewx.conf before any edit (once, idempotent across re-runs).
  if [[ -z $(backup_latest "$II_ID") ]]; then
    log_info "Backing up $WEEWX_CONF."
    backup_create "$II_ID" "$WEEWX_CONF" >/dev/null || log_warn "backup_create failed; continuing."
  fi

  # Restore the pristine pre-install weewx.conf snapshot before re-applying
  # any overlay, so DB-type switches between runs do not leave stale
  # [DataBindings]/[Databases]/[DatabaseTypes] sections behind.
  # NOTE: any manual edits to /etc/weewx/weewx.conf made after the first
  # installicious run are reverted here. Put persistent customizations in
  # overrides/weewx.override -- those are deep-merged back on top below.
  if [[ -n $(backup_latest "$II_ID") ]]; then
    backup_restore_latest "$II_ID" "$WEEWX_CONF" \
      || log_warn "restore-from-snapshot returned non-zero; continuing."
  fi

  # 1. Critical settings via weewx's own reconfigure CLI.
  if ! run_reconfigure; then
    log_fail "weewx reconfigure pass failed."
    backup_restore_or_remove "$II_ID" "$WEEWX_CONF" || log_warn "restore returned non-zero."
    status_mark_failed "$II_ID" "reconfigure failed"
    return 1
  fi

  # 2. Optional overrides deep-merged onto the result.
  if ! apply_overrides; then
    log_fail "weewx.conf override merge failed."
    backup_restore_or_remove "$II_ID" "$WEEWX_CONF" || log_warn "restore returned non-zero."
    status_mark_failed "$II_ID" "override merge failed"
    return 1
  fi

  # --- Database overlay -----------------------------------------------------
  # Sourced from /etc/installicious/state/database.state (written by the
  # feature-database-* child that just ran). When DATABASE_TYPE is mysql or
  # mariadb, overlay the right [DataBindings]/[Databases]/[DatabaseTypes]
  # sections onto /etc/weewx/weewx.conf so WeeWX uses the picked backend.
  # SQLite is a no-op -- weewx ships with archive_sqlite as the default
  # binding.
  local DATABASE_STATE_FILE DATABASE_CREDS_FILE _db_host_resolved _db_overlay
  DATABASE_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/database.state"
  DATABASE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/database.creds"
  if [[ -f $DATABASE_STATE_FILE ]]; then
    # shellcheck disable=SC1090
    source "$DATABASE_STATE_FILE"
    [[ -f $DATABASE_CREDS_FILE ]] && source "$DATABASE_CREDS_FILE"
  fi

  case "${DATABASE_TYPE:-sqlite}" in
    ""|sqlite)
      log_info "DATABASE_TYPE=${DATABASE_TYPE:-sqlite} - no weewx.conf DB overlay needed."

      # Optional seed: if overrides/weewx.sdb.override exists AND the
      # live DB is empty (no archive rows), copy the override in as the
      # starting database. weewx is already stopped (the config pass
      # above stopped it), so the copy doesn't race the daemon.
      #
      # "Empty" check, in order of trust:
      #   1. Target file missing → seed.
      #   2. sqlite3 available → query `SELECT COUNT(*) FROM archive`.
      #      Zero rows = no actual weather data, safe to seed. Any rows
      #      = real data, preserve. This is the semantic check — what
      #      we actually care about, independent of schema size.
      #   3. sqlite3 unavailable → size fallback at 1 MiB. WeeWX 5
      #      lays down ~512 KiB of schema-only tables (archive +
      #      archive_day_* per observation) even with zero rows, so the
      #      original 100 KiB threshold missed every empty-on-Trixie
      #      install. 1 MiB is well above the schema baseline and well
      #      below any real-data DB after a few hours of accumulation.
      #
      # To force a re-seed after the live DB has accumulated data, stop
      # weewx, delete /var/lib/weewx/weewx.sdb, and re-run the
      # installer (and delete /etc/installicious/status/weewx-setup.status
      # too if the feature would otherwise skip via status_should_skip).
      local _seed_src _seed_tgt _live_size _rows _should_seed _seed_reason
      _seed_src="${PATH_OVERRIDES:-overrides}/weewx.sdb.override"
      _seed_tgt="/var/lib/weewx/weewx.sdb"
      _should_seed=false
      _seed_reason=""
      if [[ -r $_seed_src ]]; then
        if [[ ! -f $_seed_tgt ]]; then
          _should_seed=true
          _seed_reason="target missing"
        elif command -v sqlite3 >/dev/null 2>&1; then
          _rows=$(sqlite3 "$_seed_tgt" 'SELECT COUNT(*) FROM archive' 2>/dev/null)
          if [[ "$_rows" =~ ^[0-9]+$ ]]; then
            if [[ "$_rows" -eq 0 ]]; then
              _should_seed=true
              _seed_reason="archive table has 0 rows (sqlite3 says empty)"
            else
              _seed_reason="archive table has $_rows rows — preserving live data"
            fi
          else
            # sqlite3 ran but returned non-numeric (DB corrupted, locked,
            # etc.). Fall through to the size check below.
            _seed_reason=""
          fi
        fi
        # Fall back to size check if the semantic check didn't decide.
        if [[ $_should_seed == false && -z $_seed_reason ]]; then
          _live_size=0
          [[ -f $_seed_tgt ]] && _live_size=$(stat -c %s "$_seed_tgt" 2>/dev/null || echo 0)
          if [[ $_live_size -lt 1048576 ]]; then
            _should_seed=true
            _seed_reason="live DB ${_live_size}B < 1 MiB threshold (sqlite3 fallback)"
          else
            _seed_reason="live DB ${_live_size}B >= 1 MiB and sqlite3 unavailable — preserving"
          fi
        fi
        if [[ $_should_seed == true ]]; then
          log_info "Seeding $_seed_tgt from $_seed_src ($(stat -c %s "$_seed_src" 2>/dev/null) bytes) — $_seed_reason."
          sudo install -o weewx -g weewx -m 0664 "$_seed_src" "$_seed_tgt" 2>&1 \
            | tee -a "$FILE_LOG_INSTALLER" \
            || log_warn "Seed copy failed; leaving live DB alone."
        else
          log_info "Preserving $_seed_tgt — $_seed_reason."
        fi
      fi
      ;;
    mysql|mariadb)
      _db_host_resolved="$DATABASE_HOST"
      # SELF / self / empty -> "localhost" (weewx wants a host string).
      # An explicit 127.0.0.1 is left as-is; weewx will TCP-connect to
      # 127.0.0.1 rather than going through the unix socket. Behavior is
      # correct either way -- mariadb-server listens on both. The
      # asymmetry with lib/database.sh's database_is_local (which DOES
      # treat 127.0.0.1 as local-for-install-purposes) is intentional:
      # the install check is about "do we own this server?", the weewx
      # config write is about "what string does WeeWX use to connect?".
      case "$_db_host_resolved" in SELF|self|"") _db_host_resolved="localhost" ;; esac

      # Guard mktemp: a failure (full disk, broken /tmp) would leave
      # $_db_overlay empty and `cat > ""` would silently dump to the cwd.
      # Skip the overlay with a clear warn instead.
      if _db_overlay=$(mktemp 2>/dev/null) && [[ -n $_db_overlay ]]; then
        cat > "$_db_overlay" <<INI
# Auto-generated overlay (DATABASE_TYPE=$DATABASE_TYPE) -- merged onto
# /etc/weewx/weewx.conf by feature-weewx-setup.
[DataBindings]
    [[wx_binding]]
        database = archive_mysql
[Databases]
    [[archive_mysql]]
        database_name = $DATABASE_NAME
        database_type = MySQL
[DatabaseTypes]
    [[MySQL]]
        host     = $_db_host_resolved
        port     = ${DATABASE_PORT:-3306}
        user     = $DATABASE_USER
        password = $DATABASE_PASS
        driver   = weedb.mysql
INI
        log_info "Merging DB overlay onto $WEEWX_CONF (host=$_db_host_resolved type=$DATABASE_TYPE)."
        sudo python3 "$MERGE_HELPER" "$WEEWX_CONF" "$_db_overlay" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
          || log_warn "weewx-merge-overrides.py returned non-zero for the DB overlay."
        rm -f "$_db_overlay"
      else
        log_warn "mktemp failed; skipping DB overlay (weewx.conf may not pick up DATABASE_TYPE=$DATABASE_TYPE on this run)."
      fi

      # --- Local-MySQL/MariaDB schema sanity --------------------------------
      # Only meaningful when the server is local (we own it). For remote
      # DATABASE_HOST we can't (and shouldn't) reach in and reset.
      if [[ $_db_host_resolved == "localhost" || $_db_host_resolved == "127.0.0.1" ]]; then
        # Wait for mariadb to actually be reachable. The apt-install of
        # mariadb-server in feature-database-mysql brings the service up
        # asynchronously; on a fresh boot the socket can lag the systemd
        # "active" state by a couple seconds. Without this wait, weewx's
        # imminent restart would print "Connection refused" and either
        # sleep-60-and-retry (ok-ish) or die from a SIGTERM mid-sleep
        # (what bit the user on this Pi).
        local _db_wait=0
        while [[ $_db_wait -lt 30 ]]; do
          if sudo -n mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
            break
          fi
          sleep 1
          _db_wait=$((_db_wait + 1))
        done
        if ! sudo -n mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
          log_warn "mariadb root-socket ping still failing after ${_db_wait}s; weewx restart may race."
        fi

        # weewx 5's _initialize_day_tables emits bare `CREATE TABLE` (no
        # IF NOT EXISTS), so an upgrade or interrupted prior install that
        # left a half-built or fully-built schema in mariadb makes the
        # next weewx start crash with "table already exists". Workaround:
        # before restarting weewx, query the live `archive` row count.
        # Empty (or missing) → DROP + CREATE the database so weewx
        # rebuilds the schema cleanly on first connect. Any rows → leave
        # it alone (real data, never wipe).
        local _archive_rows
        _archive_rows=$(sudo -n mysql -u root -N -e "USE \`${DATABASE_NAME:-weewx}\`; SELECT COUNT(*) FROM archive;" 2>/dev/null)
        if [[ -z $_archive_rows || $_archive_rows == "0" ]]; then
          log_info "Resetting empty weewx schema (DROP/CREATE DATABASE \`${DATABASE_NAME:-weewx}\`) so weewx initializes cleanly on restart — no real archive data to preserve."
          sudo -n mysql -u root <<SQL 2>&1 | tee -a "$FILE_LOG_INSTALLER" >/dev/null
DROP DATABASE IF EXISTS \`${DATABASE_NAME:-weewx}\`;
CREATE DATABASE \`${DATABASE_NAME:-weewx}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
        else
          log_info "weewx archive table has ${_archive_rows} rows — preserving live data (no schema reset)."
        fi
      fi
      ;;
    *)
      log_warn "Unknown DATABASE_TYPE='$DATABASE_TYPE' - no DB overlay."
      ;;
  esac

  if [[ $weewx_was_active == "true" ]]; then
    log_info "Restarting weewx."
    sudo systemctl start weewx || log_warn "weewx restart returned non-zero."
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX" "$OVERRIDE_FILE"
  log_ok "weewx-setup applied."
  echo -e "[  \e[0;32mOK\e[0m  ] WeeWX station configured non-interactively (weewx.conf updated)."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "weewx-setup already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] weewx-setup is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record for weewx-setup; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  local weewx_was_active=false
  if systemctl is-active --quiet weewx 2>/dev/null; then
    weewx_was_active=true
    sudo systemctl stop weewx 2>/dev/null || true
  fi

  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $WEEWX_CONF from snapshot."
    backup_restore_or_remove "$II_ID" "$WEEWX_CONF" || log_warn "weewx.conf restore returned non-zero."
  else
    log_warn "No snapshot for weewx-setup — leaving the current $WEEWX_CONF in place."
  fi

  if [[ $weewx_was_active == "true" ]]; then
    sudo systemctl start weewx || log_warn "weewx restart returned non-zero."
  fi

  status_mark_uninstalled "$II_ID"
  log_ok "weewx-setup uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] weewx-setup uninstalled (weewx.conf restored from snapshot)."
  return 0
}

do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err

  if ! err=$(verify_systemd_active weewx 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_file_exists /etc/weewx/weewx.conf 2>&1); then echo "$err"; rc=1; fi
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
