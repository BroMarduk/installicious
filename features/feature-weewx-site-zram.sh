#!/bin/bash

# Module:      WeeWX site ramdisk (tmpfs)
# Description: Moves WeeWX's report directory ($WEEWX_WEB_DIR, default
#              /var/www/html/weewx) onto a tmpfs so the ~5-minute report
#              regeneration cycle stops hammering the SD card.
#
#              On install:
#                1. Adds a tmpfs entry to /etc/fstab for WEEWX_WEB_DIR,
#                   sized by $WEEWX_TMPFS_SIZE (default 128M), owned by
#                   weewx:weewx, mode 0755.
#                2. Mounts it immediately (if not already mounted) so the
#                   feature works without a reboot.
#                3. Installs resources/weewx-loading.html as the master
#                   copy at /usr/local/share/weewx-ramdisk/loading.html,
#                   plus a systemd oneshot service that copies it onto
#                   the (volatile) tmpfs at every boot — BEFORE nginx /
#                   apache / lighttpd / caddy + weewx start. The unit's
#                   ConditionPathExists=! makes it a no-op once weewx
#                   has caught up and regenerated a real index.html.
#
#              Symmetric uninstall: disables + removes the loading-page
#              unit, removes the share dir + master copy, removes the
#              fstab line, unmounts the tmpfs. Any data on the tmpfs is
#              volatile by definition so the unmount is lossless.

# === II_MANIFEST_BEGIN ===
II_ID="weewx-site-zram"
II_TITLE="WeeWX site on tmpfs (with boot loading page)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="webserver weewx"
II_REQUIRES_REBOOT="conditional"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_EDITABLE_CONFIG="WEEWX_WEB_DIR WEEWX_TMPFS_SIZE"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/backup.sh

FILE_CONFIG_WEEWX="${PATH_CONFIG:-config}/weewx.config"
[[ -f $FILE_CONFIG_WEEWX ]] && source "$FILE_CONFIG_WEEWX"
state_apply_menu_overrides
WEEWX_WEB_DIR="${WEEWX_WEB_DIR:-/var/www/html/weewx}"
WEEWX_TMPFS_SIZE="${WEEWX_TMPFS_SIZE:-128M}"

SHARE_DIR="/usr/local/share/weewx-ramdisk"
LOADING_SRC="${SHARE_DIR}/loading.html"
LOADING_RESOURCE="${PATH_RESOURCES:-resources}/weewx-loading.html"
UNIT_NAME="weewx-loading-page.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
FSTAB="/etc/fstab"
FSTAB_TAG="# installicious: weewx-site-zram"

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

# fstab_has_entry — rc=0 if /etc/fstab already has a tmpfs line for
# WEEWX_WEB_DIR (ours or otherwise). Used to skip the append so we
# never duplicate the entry on a re-run.
fstab_has_entry() {
  grep -qE "^[[:space:]]*tmpfs[[:space:]]+${WEEWX_WEB_DIR//\//\\/}[[:space:]]+tmpfs\b" "$FSTAB" 2>/dev/null
}

# Returns the systemd-escaped name of the .mount unit auto-generated
# from /etc/fstab for WEEWX_WEB_DIR (e.g. var-www-html-weewx.mount).
weewx_mount_unit_name() {
  systemd-escape -p --suffix=mount "$WEEWX_WEB_DIR" 2>/dev/null
}

do_install() {
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX"; then
    log_info "weewx-site-zram already installed at recorded version + config. Skipping."
    return 0
  fi
  status_mark_started "$II_ID"

  if [[ ! -f $LOADING_RESOURCE ]]; then
    log_fail "Loading-page resource missing at $LOADING_RESOURCE."
    status_mark_failed "$II_ID" "resource missing"
    return 1
  fi

  # 1. fstab entry (idempotent). Snapshot /etc/fstab on first touch.
  if ! fstab_has_entry; then
    if [[ -z $(backup_latest "$II_ID") ]]; then
      log_info "Backing up $FSTAB."
      backup_create "$II_ID" "$FSTAB" >/dev/null || log_warn "backup_create failed; continuing."
    fi
    log_info "Adding tmpfs entry for $WEEWX_WEB_DIR to $FSTAB."
    local fstab_line="tmpfs  ${WEEWX_WEB_DIR}  tmpfs  noatime,nosuid,size=${WEEWX_TMPFS_SIZE},uid=weewx,gid=weewx,mode=0755  0  0  ${FSTAB_TAG}"
    echo "$fstab_line" | sudo tee -a "$FSTAB" >/dev/null \
      || { status_mark_failed "$II_ID" "fstab append failed"; return 1; }
  else
    log_info "$FSTAB already has an entry for $WEEWX_WEB_DIR; leaving it alone."
  fi
  sudo systemctl daemon-reload

  # 2. ensure mountpoint dir exists, then mount the tmpfs if not already.
  sudo mkdir -p "$WEEWX_WEB_DIR" \
    || { status_mark_failed "$II_ID" "mkdir $WEEWX_WEB_DIR failed"; return 1; }
  if ! mountpoint -q "$WEEWX_WEB_DIR"; then
    log_info "Mounting tmpfs at $WEEWX_WEB_DIR."
    if ! sudo mount "$WEEWX_WEB_DIR" 2>&1 | tee -a "$FILE_LOG_INSTALLER"; then
      log_warn "Immediate mount failed; mount will activate on next reboot."
    fi
  fi

  # 3. master loading-page copy (on SD card, persistent).
  sudo mkdir -p "$SHARE_DIR" \
    || { status_mark_failed "$II_ID" "mkdir $SHARE_DIR failed"; return 1; }
  log_info "Installing $LOADING_SRC."
  sudo install -m 0644 "$LOADING_RESOURCE" "$LOADING_SRC" \
    || { status_mark_failed "$II_ID" "loading.html install failed"; return 1; }

  # 4. boot-time oneshot that drops loading.html onto the tmpfs unless
  # weewx has already regenerated a real index.html. The After= waits on
  # the auto-generated .mount so we never race with the tmpfs.
  local mount_unit
  mount_unit=$(weewx_mount_unit_name)
  log_info "Writing $UNIT_FILE."
  sudo tee "$UNIT_FILE" >/dev/null <<UNIT_EOF
[Unit]
Description=Install WeeWX loading page onto tmpfs
DefaultDependencies=no
After=${mount_unit} local-fs.target
Requires=${mount_unit}
Before=nginx.service apache2.service lighttpd.service caddy.service weewx.service
ConditionPathExists=!${WEEWX_WEB_DIR}/index.html

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/cp ${LOADING_SRC} ${WEEWX_WEB_DIR}/index.html
ExecStart=/bin/chown weewx:weewx ${WEEWX_WEB_DIR}/index.html
ExecStart=/bin/chmod 0644 ${WEEWX_WEB_DIR}/index.html

[Install]
WantedBy=multi-user.target
UNIT_EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$UNIT_NAME" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
    || log_warn "systemctl enable returned non-zero."

  # 5. drop loading page in NOW if the tmpfs is mounted and empty so the
  # site is immediately reachable (otherwise the user'd see "It works!"
  # / "Welcome to nginx!" / blank until reboot or the next weewx cycle).
  if mountpoint -q "$WEEWX_WEB_DIR" && [[ ! -f "${WEEWX_WEB_DIR}/index.html" ]]; then
    log_info "Seeding ${WEEWX_WEB_DIR}/index.html with the loading page."
    sudo cp "$LOADING_SRC" "${WEEWX_WEB_DIR}/index.html"
    sudo chown weewx:weewx "${WEEWX_WEB_DIR}/index.html" 2>/dev/null || true
    sudo chmod 0644 "${WEEWX_WEB_DIR}/index.html"
  fi

  status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_WEEWX"
  log_ok "weewx-site-zram installed."
  echo -e "[  \e[0;32mOK\e[0m  ] WeeWX site is now on tmpfs at $WEEWX_WEB_DIR."
  return 0
}

do_uninstall() {
  case "$(status_state "$II_ID")" in
    uninstalled)
      log_info "weewx-site-zram already uninstalled."
      echo -e "[  \e[0;32mOK\e[0m  ] weewx-site-zram is already uninstalled."
      return 0
      ;;
    "")
      log_warn "No install record for weewx-site-zram; nothing to revert."
      status_mark_uninstalled "$II_ID"
      return 0
      ;;
  esac

  # 1. disable + remove the loading-page unit.
  if [[ -f $UNIT_FILE ]]; then
    log_info "Disabling + removing $UNIT_FILE."
    sudo systemctl disable "$UNIT_NAME" 2>/dev/null || true
    sudo rm -f "$UNIT_FILE"
  fi

  # 2. drop the share dir + master copy.
  if [[ -d $SHARE_DIR ]]; then
    log_info "Removing $SHARE_DIR."
    sudo rm -rf "$SHARE_DIR"
  fi

  # 3. unmount the tmpfs (lossless — its contents are regenerated reports).
  if mountpoint -q "$WEEWX_WEB_DIR"; then
    log_info "Unmounting tmpfs at $WEEWX_WEB_DIR."
    sudo umount "$WEEWX_WEB_DIR" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
      || log_warn "umount returned non-zero (likely lazy-busy); will release at reboot."
  fi

  # 4. restore /etc/fstab from snapshot (re-adds whatever was there
  # pre-install — typically nothing for this dir). Fall back to a
  # targeted line-removal by FSTAB_TAG if there's no snapshot.
  if [[ -n $(backup_latest "$II_ID") ]]; then
    log_info "Restoring $FSTAB from snapshot."
    backup_restore_or_remove "$II_ID" "$FSTAB" || log_warn "fstab restore returned non-zero."
  else
    sudo sed -i "\|${FSTAB_TAG}\$|d" "$FSTAB" 2>/dev/null || true
  fi
  sudo systemctl daemon-reload

  status_mark_uninstalled "$II_ID"
  log_ok "weewx-site-zram uninstalled."
  echo -e "[  \e[0;32mOK\e[0m  ] weewx-site-zram uninstalled (tmpfs removed, fstab restored)."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
