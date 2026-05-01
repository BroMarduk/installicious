#!/bin/bash

# Module:      Bash Customizer
# Description: Installs bash customizations (PS1 prompt + color/listing aliases)
#              for root and the target user. Idempotent: re-running replaces the
#              managed blocks in place. Reversible:
#                --uninstall                  strips the managed blocks (default)
#                --uninstall --restore-backup restores .bashrc from latest backup
#
# Usage:
#   bash installers/install-bash.sh                     # install
#   bash installers/install-bash.sh --uninstall         # strip managed blocks
#   bash installers/install-bash.sh --uninstall --restore-backup
#                                                       # restore from latest snapshot
#   --target-user=NAME overrides the auto-detected user (SUDO_USER or USER).
#
# Bump II_VERSION to force re-running install on the next pass.

II_VERSION="1"
INSTALLER_ID="bash"
MODULE="Bash Customizer"

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/backup.sh
source lib/block.sh

MODE="install"
RESTORE_BACKUP=0
TARGET_USER="${SUDO_USER:-${USER:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)         MODE="install" ;;
    --uninstall)       MODE="uninstall" ;;
    --restore-backup)  RESTORE_BACKUP=1 ;;
    --target-user=*)   TARGET_USER="${1#*=}" ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# Bump II_VERSION/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$MODULE" "$FILE_LOG_INSTALLER"

if [[ -z $TARGET_USER ]]; then
  log_fail "Could not determine target user; pass --target-user=NAME or set SUDO_USER/USER."
  exit 2
fi
USER_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
if [[ -z $USER_HOME || ! -d $USER_HOME ]]; then
  log_fail "Could not resolve home directory for user '$TARGET_USER'."
  exit 2
fi

ROOT_RC="/root/.bashrc"
USER_RC="$USER_HOME/.bashrc"

ROOT_PS1_START="# ----- Installicious ROOT PS1 (managed) -----"
ROOT_PS1_END="# ----- END Installicious ROOT PS1 -----"
ROOT_ALIAS_START="# ----- Installicious ROOT ALIAS (managed) -----"
ROOT_ALIAS_END="# ----- END Installicious ROOT ALIAS -----"
USER_ALIAS_START="# ----- Installicious USER ALIAS (managed) -----"
USER_ALIAS_END="# ----- END Installicious USER ALIAS -----"

do_install() {
  if status_should_skip "$INSTALLER_ID" "$II_VERSION"; then
    log_info "Bash customizations already at recorded version. Skipping."
    return 0
  fi
  status_mark_started "$INSTALLER_ID"

  log_info "Backing up .bashrc files for $TARGET_USER + root."
  local snap
  snap=$(backup_create "$INSTALLER_ID" "$ROOT_RC" "$USER_RC")
  if [[ -z $snap ]]; then
    log_fail "Failed to create backup snapshot."
    status_mark_failed "$INSTALLER_ID" "backup_create returned empty path"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not back up .bashrc files."
    return 1
  fi
  log_info "Snapshot at $snap."

  log_info "Configuring $ROOT_RC."
  block_ensure "$ROOT_RC" "$ROOT_PS1_START" "$ROOT_PS1_END" <<'EOF'
# Root: red username, blue working dir
PS1='${debian_chroot:+($debian_chroot)}\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF
  block_ensure "$ROOT_RC" "$ROOT_ALIAS_START" "$ROOT_ALIAS_END" <<'EOF'
export LS_OPTIONS='--color=auto'
if command -v dircolors >/dev/null 2>&1; then
  eval "$(dircolors -b)"
fi
alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lA'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias dir='ls $LS_OPTIONS -la'
EOF

  log_info "Configuring $USER_RC."
  block_ensure "$USER_RC" "$USER_ALIAS_START" "$USER_ALIAS_END" <<'EOF'
force_color_prompt=yes
alias ls='ls --color=auto'
alias dir='ls -la --color=auto'
alias vdir='vdir --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
# Trailing space lets aliases be expanded after sudo.
alias sudo='sudo '
EOF

  status_mark_complete "$INSTALLER_ID" "$II_VERSION"
  log_ok "Bash customizations applied for root and $TARGET_USER."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully customized bash."
  return 0
}

do_uninstall() {
  if [[ $RESTORE_BACKUP -eq 1 ]]; then
    log_info "Restoring .bashrc files from latest backup snapshot."
    if ! backup_restore_latest "$INSTALLER_ID" "$ROOT_RC" "$USER_RC"; then
      log_warn "No backup snapshot available; falling back to strip-block uninstall."
      RESTORE_BACKUP=0
    fi
  fi
  if [[ $RESTORE_BACKUP -eq 0 ]]; then
    log_info "Stripping managed blocks from .bashrc files."
    block_remove "$ROOT_RC" "$ROOT_PS1_START"   "$ROOT_PS1_END"
    block_remove "$ROOT_RC" "$ROOT_ALIAS_START" "$ROOT_ALIAS_END"
    block_remove "$USER_RC" "$USER_ALIAS_START" "$USER_ALIAS_END"
  fi
  status_mark_uninstalled "$INSTALLER_ID"
  log_ok "Bash customizations removed."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully removed bash customizations."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
