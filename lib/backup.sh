#!/bin/bash

# lib/backup.sh - Centralized file backup helpers for installicious.
#
# Backups for an installer "<id>" live under $PATH_BACKUP/<id>/<timestamp>/
# and preserve the original path tree of each file. Example:
#
#   $PATH_BACKUP/bash/20260501-080000/root/.bashrc
#   $PATH_BACKUP/bash/20260501-080000/home/dan/.bashrc
#
# This makes restore trivial — read the file from
# $PATH_BACKUP/<id>/<ts>$ORIGINAL_PATH and copy it back to $ORIGINAL_PATH.
#
# Usage:
#   backup_create <id> <file...>             # snapshot now; echoes timestamp dir path
#   backup_restore_latest <id> <file...>     # restore each file from the newest snapshot
#   backup_list <id>                         # echo timestamps newest-first
#   backup_latest <id>                       # echo just the newest timestamp (or empty)
#
# Configuration consumed (must be in scope, typically via installicious.config):
#   PATH_BACKUP - directory under installicious where snapshots live

_backup_root() {
  echo "${PATH_BACKUP:-backup}"
}

_backup_timestamp() {
  date +%Y%m%d-%H%M%S
}

# backup_create <id> <file...>
# Creates $PATH_BACKUP/<id>/<timestamp>/ and copies each existing file into it,
# preserving the file's original directory tree. Files that don't exist are
# silently skipped (e.g. the .bashrc we're about to create). Echoes the snapshot
# directory path on stdout. Returns non-zero only on mkdir/cp failure.
backup_create() {
  local id="$1"
  shift
  local ts
  ts=$(_backup_timestamp)
  local snap="$(_backup_root)/${id}/${ts}"
  sudo mkdir -p "$snap" || return 1
  local f target
  for f in "$@"; do
    [[ -f $f ]] || continue
    target="${snap}${f}"   # /etc/foo -> $snap/etc/foo
    sudo mkdir -p "$(dirname "$target")"
    sudo cp -a "$f" "$target" || return 1
  done
  echo "$snap"
}

# backup_latest <id> -> echo newest timestamp dir name (just the basename), or empty.
backup_latest() {
  local id="$1"
  local id_dir="$(_backup_root)/${id}"
  [[ -d $id_dir ]] || return 0
  ls -1 "$id_dir" 2>/dev/null | sort -r | head -n 1
}

# backup_list <id> -> echo timestamps newest-first, one per line.
backup_list() {
  local id="$1"
  local id_dir="$(_backup_root)/${id}"
  [[ -d $id_dir ]] || return 0
  ls -1 "$id_dir" 2>/dev/null | sort -r
}

# backup_restore_latest <id> <file...>
# Restore each file from the newest snapshot. Files not present in that snapshot
# are skipped (with a notice on stderr). Returns 0 if any file was restored,
# 1 if no snapshot exists, 2 if a snapshot exists but no listed files were in it.
backup_restore_latest() {
  local id="$1"
  shift
  local ts
  ts=$(backup_latest "$id")
  if [[ -z $ts ]]; then
    return 1
  fi
  local snap="$(_backup_root)/${id}/${ts}"
  local f source any=0
  for f in "$@"; do
    source="${snap}${f}"
    if [[ -f $source ]]; then
      sudo cp -a "$source" "$f" || return 1
      any=1
    else
      echo "backup_restore_latest: no entry for $f in snapshot $ts" >&2
    fi
  done
  [[ $any -eq 1 ]] && return 0 || return 2
}

# backup_restore_or_remove <id> <file...>
# Drives a full pre-install reversion: for each file, if it's present in the
# latest snapshot, restore it; otherwise the file did not exist pre-install and
# was created by us, so remove it. Returns 1 if no snapshot exists at all
# (caller should decide whether to proceed conservatively).
backup_restore_or_remove() {
  local id="$1"
  shift
  local ts
  ts=$(backup_latest "$id")
  if [[ -z $ts ]]; then
    return 1
  fi
  local snap="$(_backup_root)/${id}/${ts}"
  local f source
  for f in "$@"; do
    source="${snap}${f}"
    if [[ -f $source ]]; then
      sudo cp -a "$source" "$f" || return 2
    elif [[ -f $f ]]; then
      sudo rm -f "$f" || return 3
    fi
  done
  return 0
}
