#!/bin/bash

# Module:      Bash Customizer
# Description: Edits the existing Pi OS default .bashrc files in place — does
#              NOT append managed sentinel blocks. For root: replaces the
#              simple commented PS1 with a colored one, uncomments the standard
#              alias lines, and inserts `alias dir='ls $LS_OPTIONS -la'`. For
#              the local user: uncomments force_color_prompt + the standard
#              alias lines, switches the dir alias to `ls -la --color=auto`,
#              uncomments vdir, and appends `alias sudo='sudo '`.
#
#              --uninstall: re-comments the lines we uncommented, swaps the
#                           PS1 back to the default form, removes the lines
#                           we added.
#              --uninstall --restore-backup: full snapshot restore.
#
# All transforms are exact-line matches (via grep -Fx + awk), so no sed
# escaping headaches. Re-running install is a no-op when the target line is
# already in place.
#
# Bump II_VERSION to force a re-run on the next pass.

# === II_MANIFEST_BEGIN ===
II_ID="bash"
II_TITLE="Bash Customizer"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/backup.sh
source lib/block.sh

# os.status carries II_INSTALLICIOUS_USER, set by installicious.sh from
# $SUDO_USER. Survives nested sudo + post-reboot resume.
[[ -f "$PATH_STATUS/os.status" ]] && source "$PATH_STATUS/os.status"

MODE="install"
RESTORE_BACKUP=0
TARGET_USER="${II_INSTALLICIOUS_USER:-${SUDO_USER:-${USER:-}}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)         MODE="install" ;;
    --uninstall)       MODE="uninstall" ;;
    --restore-backup)  RESTORE_BACKUP=1 ;;
    --target-user=*)   TARGET_USER="${1#*=}" ;;
    -h|--help)
      sed -n '/^# Module:/,/^# Bump II_VERSION/p' "$0" | sed 's/^# \{0,1\}//'
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
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

if [[ -z $TARGET_USER ]]; then
  log_fail "Could not determine target user; pass --target-user=NAME or set II_INSTALLICIOUS_USER in os.status."
  exit 2
fi

ROOT_RC="/root/.bashrc"
USER_RC=""
if [[ $TARGET_USER != "root" ]]; then
  USER_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
  if [[ -n $USER_HOME && -d $USER_HOME ]]; then
    USER_RC="$USER_HOME/.bashrc"
  else
    log_warn "Could not resolve home for '$TARGET_USER'; only /root/.bashrc will be configured."
  fi
fi

# ===========================================================================
# Line-level edit helpers (grep -Fx + awk for exact-string matching, so we
# don't have to think about regex escaping).
# ===========================================================================

# replace_line <file> <from> <to>
# If $to already in file: no-op. If $from in file: replace it with $to.
# Returns 1 (with a warn) when neither is present.
#
# Note: we pass strings via ENVIRON[] rather than awk -v, because -v processes
# backslash escapes in the value (\h becomes h, \$ becomes $) — which would
# destroy our PS1 / alias content. ENVIRON[] preserves bytes verbatim.
replace_line() {
  local file="$1" from="$2" to="$3"
  [[ -f $file ]] || return 1
  if grep -qFx -- "$to" "$file" 2>/dev/null; then
    return 0
  fi
  if ! grep -qFx -- "$from" "$file" 2>/dev/null; then
    log_warn "replace_line: source not found in $(basename "$file"): $from"
    return 1
  fi
  local owner tmp
  owner=$(stat -c '%U:%G' "$file" 2>/dev/null)
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  AWK_FROM="$from" AWK_TO="$to" awk '
    $0 == ENVIRON["AWK_FROM"] {print ENVIRON["AWK_TO"]; next}
    {print}
  ' "$file" > "$tmp"
  sudo mv -f "$tmp" "$file" 2>/dev/null || mv -f "$tmp" "$file"
  [[ -n $owner ]] && (chown "$owner" "$file" 2>/dev/null || sudo chown "$owner" "$file" 2>/dev/null) || true
  return 0
}

# insert_after_line <file> <anchor> <new_line>
# If $new_line already in file: no-op. Otherwise insert $new_line after first
# exact-match $anchor.
insert_after_line() {
  local file="$1" anchor="$2" new_line="$3"
  [[ -f $file ]] || return 1
  if grep -qFx -- "$new_line" "$file" 2>/dev/null; then
    return 0
  fi
  if ! grep -qFx -- "$anchor" "$file" 2>/dev/null; then
    log_warn "insert_after_line: anchor not found in $(basename "$file"): $anchor"
    return 1
  fi
  local owner tmp
  owner=$(stat -c '%U:%G' "$file" 2>/dev/null)
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  AWK_ANCHOR="$anchor" AWK_LINE="$new_line" awk '
    {print}
    !inserted && $0 == ENVIRON["AWK_ANCHOR"] {print ENVIRON["AWK_LINE"]; inserted=1}
  ' "$file" > "$tmp"
  sudo mv -f "$tmp" "$file" 2>/dev/null || mv -f "$tmp" "$file"
  [[ -n $owner ]] && (chown "$owner" "$file" 2>/dev/null || sudo chown "$owner" "$file" 2>/dev/null) || true
  return 0
}

# append_line_if_missing <file> <line>
# Appends $line to the file when it isn't already present.
append_line_if_missing() {
  local file="$1" line="$2"
  [[ -f $file ]] || return 1
  if grep -qFx -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  local owner
  owner=$(stat -c '%U:%G' "$file" 2>/dev/null)
  printf '\n%s\n' "$line" | sudo tee -a "$file" >/dev/null
  [[ -n $owner ]] && (chown "$owner" "$file" 2>/dev/null || sudo chown "$owner" "$file" 2>/dev/null) || true
}

# remove_line <file> <line>
# Removes every exact match of $line. Idempotent.
remove_line() {
  local file="$1" line="$2"
  [[ -f $file ]] || return 0
  if ! grep -qFx -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  local owner tmp
  owner=$(stat -c '%U:%G' "$file" 2>/dev/null)
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  AWK_TARGET="$line" awk '$0 != ENVIRON["AWK_TARGET"]' "$file" > "$tmp"
  sudo mv -f "$tmp" "$file" 2>/dev/null || mv -f "$tmp" "$file"
  [[ -n $owner ]] && (chown "$owner" "$file" 2>/dev/null || sudo chown "$owner" "$file" 2>/dev/null) || true
}

# ===========================================================================
# Transform definitions
# ===========================================================================

# Root .bashrc — Pi OS defaults vs target state.
ROOT_PS1_OLD="# PS1='\${debian_chroot:+(\$debian_chroot)}\\h:\\w\\\$ '"
ROOT_PS1_NEW="PS1='\${debian_chroot:+(\$debian_chroot)}\\[\\033[01;31m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\\$ '"

# (commented_form, uncommented_form) pairs. Install replaces commented->uncommented;
# uninstall reverses.
ROOT_PAIRS=(
  "# export LS_OPTIONS='--color=auto'"     "export LS_OPTIONS='--color=auto'"
  "# eval \"\$(dircolors)\""               "eval \"\$(dircolors)\""
  "# alias ls='ls \$LS_OPTIONS'"            "alias ls='ls \$LS_OPTIONS'"
  "# alias ll='ls \$LS_OPTIONS -l'"         "alias ll='ls \$LS_OPTIONS -l'"
  "# alias l='ls \$LS_OPTIONS -lA'"         "alias l='ls \$LS_OPTIONS -lA'"
  "# alias rm='rm -i'"                      "alias rm='rm -i'"
  "# alias cp='cp -i'"                      "alias cp='cp -i'"
  "# alias mv='mv -i'"                      "alias mv='mv -i'"
)
ROOT_DIR_ANCHOR="alias mv='mv -i'"
ROOT_DIR_NEW="alias dir='ls \$LS_OPTIONS -la'"

# User .bashrc — Pi OS defaults vs target state. The dir/vdir lines have a
# 4-space indent because they live inside an `if [ -x /usr/bin/dircolors ]` block.
USER_PAIRS=(
  "#force_color_prompt=yes"                  "force_color_prompt=yes"
  "#alias ll='ls -l'"                        "alias ll='ls -l'"
  "#alias la='ls -A'"                        "alias la='ls -A'"
  "#alias l='ls -CF'"                        "alias l='ls -CF'"
)
# dir alias is a *substitution*, not just an uncomment (lots of users want
# 'dir' to mean the long-listing variant rather than the dir-with-color one).
USER_DIR_OLD="    #alias dir='dir --color=auto'"
USER_DIR_NEW="    alias dir='ls -la --color=auto'"
USER_VDIR_OLD="    #alias vdir='vdir --color=auto'"
USER_VDIR_NEW="    alias vdir='vdir --color=auto'"
USER_SUDO_ALIAS="alias sudo='sudo '"

# Legacy v1 markers — stripped on first run if present (one-time migration
# from the old append-managed-blocks design).
LEGACY_MARKERS=(
  "# ----- Installicious ROOT PS1 (managed) -----"      "# ----- END Installicious ROOT PS1 -----"
  "# ----- Installicious ROOT ALIAS (managed) -----"    "# ----- END Installicious ROOT ALIAS -----"
)
LEGACY_USER_MARKERS=(
  "# ----- Installicious USER ALIAS (managed) -----"    "# ----- END Installicious USER ALIAS -----"
)

# ===========================================================================
# Install
# ===========================================================================

apply_pairs_install() {
  local file="$1"
  shift
  local i
  for ((i = 0; i < $#; i += 2)); do
    replace_line "$file" "${@:i+1:1}" "${@:i+2:1}"
  done
}

apply_pairs_uninstall() {
  local file="$1"
  shift
  local i
  for ((i = 0; i < $#; i += 2)); do
    # reverse direction: from = "uncommented", to = "commented"
    replace_line "$file" "${@:i+2:1}" "${@:i+1:1}"
  done
}

strip_legacy_blocks_root() {
  local file="$1"
  [[ -f $file ]] || return 0
  local i
  for ((i = 0; i < ${#LEGACY_MARKERS[@]}; i += 2)); do
    if grep -qFx -- "${LEGACY_MARKERS[i]}" "$file" 2>/dev/null; then
      log_info "Removing legacy v1 managed block from $file: ${LEGACY_MARKERS[i]}"
      block_remove "$file" "${LEGACY_MARKERS[i]}" "${LEGACY_MARKERS[i+1]}"
    fi
  done
}

strip_legacy_blocks_user() {
  local file="$1"
  [[ -f $file ]] || return 0
  local i
  for ((i = 0; i < ${#LEGACY_USER_MARKERS[@]}; i += 2)); do
    if grep -qFx -- "${LEGACY_USER_MARKERS[i]}" "$file" 2>/dev/null; then
      log_info "Removing legacy v1 managed block from $file: ${LEGACY_USER_MARKERS[i]}"
      block_remove "$file" "${LEGACY_USER_MARKERS[i]}" "${LEGACY_USER_MARKERS[i+1]}"
    fi
  done
}

do_install() {
  status_mark_started "$II_ID"

  local snap files=("$ROOT_RC")
  [[ -n $USER_RC ]] && files+=("$USER_RC")
  log_info "Backing up .bashrc files: ${files[*]}"
  snap=$(backup_create "$II_ID" "${files[@]}")
  if [[ -z $snap ]]; then
    log_fail "Failed to create backup snapshot."
    status_mark_failed "$II_ID" "backup_create returned empty path"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not back up .bashrc files."
    return 1
  fi
  log_info "Snapshot at $snap."

  # One-time migration: strip legacy v1 managed blocks if present.
  strip_legacy_blocks_root "$ROOT_RC"
  [[ -n $USER_RC ]] && strip_legacy_blocks_user "$USER_RC"

  # Root .bashrc edits.
  log_info "Configuring $ROOT_RC."
  replace_line "$ROOT_RC" "$ROOT_PS1_OLD" "$ROOT_PS1_NEW"
  apply_pairs_install "$ROOT_RC" "${ROOT_PAIRS[@]}"
  insert_after_line "$ROOT_RC" "$ROOT_DIR_ANCHOR" "$ROOT_DIR_NEW"

  # User .bashrc edits.
  if [[ -n $USER_RC ]]; then
    log_info "Configuring $USER_RC."
    apply_pairs_install "$USER_RC" "${USER_PAIRS[@]}"
    replace_line "$USER_RC" "$USER_DIR_OLD"  "$USER_DIR_NEW"
    replace_line "$USER_RC" "$USER_VDIR_OLD" "$USER_VDIR_NEW"
    append_line_if_missing "$USER_RC" "$USER_SUDO_ALIAS"
  fi

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "Bash customizations applied for root${USER_RC:+ and $TARGET_USER}."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully customized bash."
  return 0
}

# ===========================================================================
# Uninstall
# ===========================================================================

do_uninstall() {
  if [[ $RESTORE_BACKUP -eq 1 ]]; then
    log_info "Restoring .bashrc files from latest backup snapshot."
    local files=("$ROOT_RC")
    [[ -n $USER_RC ]] && files+=("$USER_RC")
    if ! backup_restore_latest "$II_ID" "${files[@]}"; then
      log_warn "No backup snapshot available; falling back to in-place reversal."
      RESTORE_BACKUP=0
    fi
  fi

  if [[ $RESTORE_BACKUP -eq 0 ]]; then
    log_info "Reverting in-place edits in .bashrc files."

    # Reverse root edits
    remove_line "$ROOT_RC" "$ROOT_DIR_NEW"
    apply_pairs_uninstall "$ROOT_RC" "${ROOT_PAIRS[@]}"
    replace_line "$ROOT_RC" "$ROOT_PS1_NEW" "$ROOT_PS1_OLD"

    # Reverse user edits
    if [[ -n $USER_RC ]]; then
      remove_line "$USER_RC" "$USER_SUDO_ALIAS"
      replace_line "$USER_RC" "$USER_VDIR_NEW" "$USER_VDIR_OLD"
      replace_line "$USER_RC" "$USER_DIR_NEW"  "$USER_DIR_OLD"
      apply_pairs_uninstall "$USER_RC" "${USER_PAIRS[@]}"
    fi
  fi

  # Belt-and-suspenders: also strip legacy v1 markers if any are still hanging around.
  strip_legacy_blocks_root "$ROOT_RC"
  [[ -n $USER_RC ]] && strip_legacy_blocks_user "$USER_RC"

  status_mark_uninstalled "$II_ID"
  log_ok "Bash customizations reverted."
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully removed bash customizations."
  return 0
}

if [[ $MODE == "install" ]]; then
  do_install
else
  do_uninstall
fi
exit $?
