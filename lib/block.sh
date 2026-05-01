#!/bin/bash

# lib/block.sh - Managed-block helpers for editing config files.
#
# A "managed block" is a contiguous span of lines in a file delimited by exact
# start and end marker lines, e.g.:
#
#   # ----- Installicious BLOCK_NAME (managed) -----
#   <our content>
#   # ----- END Installicious BLOCK_NAME -----
#
# block_ensure replaces or appends such a block; block_remove strips it. Both
# preserve the file's owner/group (important when an installer runs as root but
# is editing a user-owned file like ~/.bashrc).
#
# Usage:
#   block_ensure <file> <start_marker> <end_marker>   # reads new content from stdin
#   block_remove <file> <start_marker> <end_marker>   # no-op if file or block absent

# _block_capture_owner <file> -> echo "uid:gid" or empty if file does not exist.
_block_capture_owner() {
  [[ -f $1 ]] || return 0
  stat -c '%u:%g' "$1" 2>/dev/null
}

# _block_restore_owner <file> <uid:gid>
_block_restore_owner() {
  local file="$1" owner="$2"
  [[ -z $owner ]] && return 0
  if ! chown "$owner" "$file" 2>/dev/null; then
    sudo chown "$owner" "$file" 2>/dev/null || true
  fi
}

# _block_strip <file> <start_marker> <end_marker> <out_tmp>
# Writes <file> minus the managed block to <out_tmp>. If the marker is absent,
# copies the file as-is. If the file does not exist, the output is empty.
_block_strip() {
  local file="$1" start="$2" end="$3" out="$4"
  if [[ ! -f $file ]]; then
    : > "$out"
    return 0
  fi
  if grep -qxF "$start" "$file" 2>/dev/null; then
    awk -v s="$start" -v e="$end" '
      $0==s {inblk=1; next}
      $0==e {inblk=0; next}
      inblk!=1 {print}
    ' "$file" > "$out"
  else
    cat "$file" > "$out"
  fi
}

# block_ensure <file> <start_marker> <end_marker>
# Reads block content from stdin. Strips any existing block, then appends a
# fresh one. Idempotent: running again with identical content yields the same
# file. Preserves file ownership.
block_ensure() {
  local file="$1" start="$2" end="$3"
  local dir tmp owner
  dir=$(dirname "$file")
  sudo mkdir -p "$dir" 2>/dev/null || mkdir -p "$dir" || return 1
  owner=$(_block_capture_owner "$file")
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  _block_strip "$file" "$start" "$end" "$tmp"
  {
    echo "$start"
    cat
    echo "$end"
  } >> "$tmp"
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    sudo mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  fi
  _block_restore_owner "$file" "$owner"
}

# block_remove <file> <start_marker> <end_marker>
# Strips the managed block from the file. No-op if the file or block is absent.
# Preserves file ownership.
block_remove() {
  local file="$1" start="$2" end="$3"
  [[ -f $file ]] || return 0
  grep -qxF "$start" "$file" 2>/dev/null || return 0
  local tmp owner
  owner=$(_block_capture_owner "$file")
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  _block_strip "$file" "$start" "$end" "$tmp"
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    sudo mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  fi
  _block_restore_owner "$file" "$owner"
}
