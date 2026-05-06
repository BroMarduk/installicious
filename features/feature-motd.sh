#!/bin/bash

# Module:      MOTD Installer
# Description: Sets up the login Message of the Day. Installs the large + small
#              MOTD scripts under /etc/motd.d/$MOTD_NAME/, the daily IP-fetch
#              cron job, and reconfigures system files so the right MOTD is
#              shown at login (replacing the dynamic uname motd, suppressing
#              SSH's last-login banner, and appending a width-aware launcher
#              block to /etc/profile).
#
#              Optional add-on: install-motd-weather.sh layers the hourly
#              weather fetch on top via II_DEPS="motd".
#
#              System files modified (each backed up via lib/backup.sh before
#              first edit; restored on --uninstall):
#                /etc/profile               — managed block invokes motd.sh /
#                                              motd-small.sh based on tty width
#                /etc/ssh/sshd_config       — PrintMotd no, PrintLastLog no
#                /etc/pam.d/login           — comments out pam_lastlog.so
#                /etc/update-motd.d/10-uname — removed (legacy dynamic motd)
#
#              Bump II_VERSION to force a re-run.

# === II_MANIFEST_BEGIN ===
II_ID="motd"
II_TITLE="Login MOTD (banner)"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="MOTD_NAME MOTD_IP_URL MOTD_SMALL_SIZE"
II_OPTIONAL_GROUP="motd-weather motd-updates"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh
source lib/block.sh
source lib/post_install.sh

FILE_CONFIG_MOTD="${PATH_CONFIG:-config}/motd.config"
[[ -f $FILE_CONFIG_MOTD ]] && source "$FILE_CONFIG_MOTD"
state_apply_menu_overrides
MOTD_NAME="${MOTD_NAME:-dannet}"
MOTD_IP_URL="${MOTD_IP_URL:-https://api.ipify.org}"
MOTD_SMALL_SIZE="${MOTD_SMALL_SIZE:-79}"

MOTD_DIR="/etc/motd.d/$MOTD_NAME"
CRON_DAILY_IP="/etc/cron.daily/motd-current-ip"
SSHD_CONFIG="/etc/ssh/sshd_config"
PAM_LOGIN="/etc/pam.d/login"
PROFILE_FILE="/etc/profile"
DYNAMIC_MOTD="/etc/update-motd.d/10-uname"
PROFILE_BLOCK_START="# ----- Installicious motd (managed) -----"
PROFILE_BLOCK_END="# ----- END Installicious motd -----"

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

# render_resource <src> <dest>
# Copies a resources/motd-* file into place with %%TOKEN%% substitution. Uses
# `|` as the sed delimiter so URL slashes don't trip it. chmod +x on the
# destination since these are all executable scripts.
render_resource() {
  local src="$1" dest="$2"
  local tmp
  tmp=$(mktemp) || return 1
  # Only substitute tokens that actually appear in the resources this
  # installer renders (motd.sh, motd-small.sh, motd-current-ip.sh).
  # MOTD_SMALL_SIZE is used in the /etc/profile launcher heredoc below,
  # not as a sed token in any rendered file.
  sed -e "s|%%MOTD_NAME%%|${MOTD_NAME}|g" \
      -e "s|%%MOTD_IP_URL%%|${MOTD_IP_URL}|g" \
      "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m 0755 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# Comment out a pam_lastlog.so entry in /etc/pam.d/login if it's still active.
# Idempotent: a no-op if the line is already commented or absent.
disable_pam_lastlog() {
  [[ -f $PAM_LOGIN ]] || return 0
  if grep -qE '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_lastlog\.so' "$PAM_LOGIN"; then
    sudo sed -i -E 's|^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_lastlog\.so.*)|# \1|' "$PAM_LOGIN"
  fi
}

# Set a directive in sshd_config: replace existing (commented or not) or
# append. Idempotent.
sshd_set() {
  local key="$1" val="$2"
  if [[ ! -f $SSHD_CONFIG ]]; then
    log_warn "$SSHD_CONFIG not found; cannot set $key."
    return 0
  fi
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
    sudo sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*$|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" | sudo tee -a "$SSHD_CONFIG" >/dev/null
  fi
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"; then
    log_info "MOTD already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  # ---- backup the system files we'll touch (lib/backup.sh skips missing) ----
  local snap
  snap=$(backup_create "$II_ID" "$PROFILE_FILE" "$SSHD_CONFIG" "$PAM_LOGIN" "$DYNAMIC_MOTD") \
    || { log_fail "Could not create backup snapshot."; status_mark_failed "$II_ID" "backup_create failed"; return 1; }
  log_info "Backup snapshot: $snap."

  # ---- install motd resource files ----
  log_info "Installing motd scripts to $MOTD_DIR."
  sudo mkdir -p "$MOTD_DIR"
  render_resource "${PATH_RESOURCES:-resources}/motd.sh"       "$MOTD_DIR/motd.sh" \
    || { log_fail "Failed to install motd.sh."; status_mark_failed "$II_ID" "motd.sh install failed"; return 1; }
  render_resource "${PATH_RESOURCES:-resources}/motd-small.sh" "$MOTD_DIR/motd-small.sh" \
    || { log_fail "Failed to install motd-small.sh."; status_mark_failed "$II_ID" "motd-small.sh install failed"; return 1; }

  # ---- daily IP-fetch cron ----
  log_info "Installing $CRON_DAILY_IP."
  render_resource "${PATH_RESOURCES:-resources}/motd-current-ip.sh" "$CRON_DAILY_IP" \
    || { log_fail "Failed to install daily IP cron."; status_mark_failed "$II_ID" "ip cron install failed"; return 1; }

  # ---- replace dynamic motd ----
  if [[ -e $DYNAMIC_MOTD ]]; then
    log_info "Removing dynamic motd $DYNAMIC_MOTD."
    sudo rm -f "$DYNAMIC_MOTD"
  fi

  # ---- ssh: stop printing the system motd and last-login banner ----
  sshd_set PrintMotd     "no"
  sshd_set PrintLastLog  "no"

  # ---- pam: stop printing last login on console ----
  disable_pam_lastlog

  # ---- /etc/profile: append the width-aware launcher (managed block) ----
  log_info "Appending MOTD launcher block to $PROFILE_FILE."
  block_ensure "$PROFILE_FILE" "$PROFILE_BLOCK_START" "$PROFILE_BLOCK_END" <<EOF
# Installicious — show the right MOTD based on terminal width.
read screenWidth <<< \$(stty -a | awk 'NR==1 { print \$7 }')
intWidth=\${screenWidth::-1}
if [[ \$intWidth -gt $MOTD_SMALL_SIZE ]]; then
  $MOTD_DIR/motd.sh
else
  $MOTD_DIR/motd-small.sh
fi
EOF

  # ---- restart ssh so PrintMotd/PrintLastLog take effect ----
  # Defer to end-of-queue: the user may be SSH'd in right now.
  post_install_run "sudo systemctl restart ssh" \
    "Restart sshd so MOTD changes take effect on next login."

  # ---- seed the IP-results file by running the cron once now ----
  # Without this, the first login until the daily cron fires would show "None"
  # for the external IP. Failures (no network, wget timeout) are warned but
  # don't fail the install — the cron will retry tomorrow.
  if [[ -x $CRON_DAILY_IP ]]; then
    log_info "Running $CRON_DAILY_IP once to capture initial IP."
    if ! sudo "$CRON_DAILY_IP"; then
      log_warn "Initial IP fetch failed; cron will retry tomorrow."
    fi
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_MOTD"
  log_ok "MOTD installed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed the MOTD."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "MOTD already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] MOTD is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record found for motd; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # ---- restore system files from backup ----
  if backup_restore_or_remove "$II_ID" \
       "$PROFILE_FILE" "$SSHD_CONFIG" "$PAM_LOGIN" "$DYNAMIC_MOTD"; then
    log_info "System files restored from backup."
  else
    log_warn "No backup snapshot found; falling back to managed-block strip."
    block_remove "$PROFILE_FILE" "$PROFILE_BLOCK_START" "$PROFILE_BLOCK_END"
  fi

  # ---- remove our resource files ----
  if [[ -d $MOTD_DIR ]]; then
    log_info "Removing $MOTD_DIR."
    sudo rm -rf "$MOTD_DIR"
  fi
  if [[ -e $CRON_DAILY_IP ]]; then
    log_info "Removing $CRON_DAILY_IP."
    sudo rm -f "$CRON_DAILY_IP"
  fi

  # ---- restart ssh so the reverted config takes effect ----
  post_install_run "sudo systemctl restart ssh" \
    "Restart sshd to apply the reverted PrintMotd / PrintLastLog settings."

  status_mark_uninstalled "$II_ID"
  log_ok "MOTD uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully uninstalled the MOTD."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
