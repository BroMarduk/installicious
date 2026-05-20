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
#              Symmetric --uninstall: restores /etc/weewx/weewx.conf from
#              the pre-install snapshot via lib/backup.

# === II_MANIFEST_BEGIN ===
II_ID="weewx-setup"
II_TITLE="WeeWX station setup (non-interactive config)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="weewx"
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

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
