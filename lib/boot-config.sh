#!/bin/bash

# lib/boot-config.sh — Idempotent /boot/firmware/config.txt manager.
#
# First non-raspi-config writer of config.txt in installicious. Provides:
#
#   boot_config_path                       echo the active path (firmware
#                                          /boot/firmware/config.txt
#                                          preferred; legacy /boot/config.txt
#                                          fallback)
#   boot_config_backup_once                snapshot to
#                                          /etc/installicious/backup/boot-config/<ts>/
#                                          (one snapshot per installicious run)
#   boot_config_dtparam_set <k> <v>        idempotent dtparam=k=v
#                                          Contract: <key> must match
#                                          [a-zA-Z_][a-zA-Z0-9_]* (the
#                                          dtparam keys Pi firmware
#                                          recognizes). Keys containing
#                                          regex metacharacters are not
#                                          supported — the match patterns
#                                          interpolate <key> raw into a
#                                          regex.
#   boot_config_dtparam_unset <k>          comment out (preserves for rollback)
#   boot_config_overlay_add <owner> <line> add fenced block:
#                                            # === installicious:<owner> begin ===
#                                            <line>
#                                            # === installicious:<owner> end ===
#                                          Idempotent. Rewrites content
#                                          in-place between fences if
#                                          differing.
#   boot_config_overlay_remove <owner>     remove the fenced block.
#   boot_config_overlay_has <owner>        rc=0 iff block present.
#
# Implementation notes:
# - Atomic writes via mktemp + mv (mirrors lib/state.sh::_state_write_pairs).
# - CRLF tolerance per the manifest-parser CRLF fix (c5dc147).
# - Tests override the path via $BOOT_CONFIG_PATH_OVERRIDE.
# - All operations write as root (sudo themselves where needed).

# boot_config_path — echo the active config.txt path.
boot_config_path() {
  if [[ -n ${BOOT_CONFIG_PATH_OVERRIDE:-} ]]; then
    echo "$BOOT_CONFIG_PATH_OVERRIDE"
    return 0
  fi
  if [[ -e /boot/firmware/config.txt ]]; then
    echo /boot/firmware/config.txt
  elif [[ -e /boot/config.txt ]]; then
    echo /boot/config.txt
  else
    # Default to the firmware path even when missing — callers fail loudly
    # on a missing config.txt rather than silently working on a non-Pi.
    echo /boot/firmware/config.txt
  fi
}

# _boot_config_write_atomic <path> <content-stdin>
# Atomic-write helper: reads content from stdin, mktemp + mv in same dir.
# Caller is responsible for any preservation of file mode/owner — we
# preserve mode by chmod'ing the new file to match the old one.
_boot_config_write_atomic() {
  local target="$1"
  local dir tmp
  dir=$(dirname "$target")
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || tmp=$(sudo mktemp "${target}.XXXXXX")
  cat > "$tmp" 2>/dev/null || sudo tee "$tmp" > /dev/null
  # Preserve mode + ownership.
  if [[ -f $target ]]; then
    local mode owner
    mode=$(stat -c %a "$target" 2>/dev/null || stat -f %A "$target" 2>/dev/null)
    owner=$(stat -c %U:%G "$target" 2>/dev/null || stat -f '%Su:%Sg' "$target" 2>/dev/null)
    [[ -n $mode ]] && { chmod "$mode" "$tmp" 2>/dev/null || sudo chmod "$mode" "$tmp"; }
    [[ -n $owner ]] && { chown "$owner" "$tmp" 2>/dev/null || sudo chown "$owner" "$tmp"; }
  fi
  mv -f "$tmp" "$target" 2>/dev/null || sudo mv -f "$tmp" "$target"
}

# _boot_config_read <path> — echo file contents with CRLF normalized to LF.
_boot_config_read() {
  local target="$1"
  [[ -f $target ]] || return 0
  # Strip \r at end of each line.
  sed $'s/\r$//' "$target"
}

# boot_config_backup_once — copy config.txt to
# /etc/installicious/backup/boot-config/<timestamp>/config.txt. One
# snapshot per installicious run; subsequent calls are no-ops.
_BOOT_CONFIG_BACKUP_DONE=0
boot_config_backup_once() {
  [[ $_BOOT_CONFIG_BACKUP_DONE -eq 1 ]] && return 0
  local src ts dest
  src=$(boot_config_path)
  [[ -f $src ]] || { _BOOT_CONFIG_BACKUP_DONE=1; return 0; }
  ts=$(date '+%Y%m%d-%H%M%S')
  local base="${PATH_BACKUP:-/etc/installicious/backup}/boot-config/$ts"
  mkdir -p "$base" 2>/dev/null || sudo mkdir -p "$base"
  cp "$src" "$base/$(basename "$src")" 2>/dev/null \
    || sudo cp "$src" "$base/$(basename "$src")"
  _BOOT_CONFIG_BACKUP_DONE=1
}

# boot_config_dtparam_set <key> <value>
boot_config_dtparam_set() {
  local key="$1" value="$2"
  local target content new
  target=$(boot_config_path)
  content=$(_boot_config_read "$target")

  # Pass 1: look for an existing (commented or not) `dtparam=<key>=...`.
  # If found, ensure it's uncommented AND has the desired value. If
  # already correct, no-op.
  if grep -qE "^[[:space:]]*#*[[:space:]]*dtparam=${key}=" <<< "$content"; then
    new=$(awk -v k="$key" -v v="$value" '
      BEGIN { changed = 0 }
      {
        line = $0
        if (match(line, "^[[:space:]]*#*[[:space:]]*dtparam=" k "=")) {
          target = "dtparam=" k "=" v
          if (line != target) {
            print target
            changed = 1
            next
          }
        }
        print line
      }
    ' <<< "$content")
    if [[ "$new" != "$content" ]]; then
      _boot_config_write_atomic "$target" <<< "$new"
    fi
    return 0
  fi

  # Pass 2: not present at all — append.
  new="$content"$'\n'"dtparam=${key}=${value}"
  _boot_config_write_atomic "$target" <<< "$new"
}

# boot_config_dtparam_unset <key>
# Comments out the line (preserves for rollback). If already commented or
# absent, no-op.
boot_config_dtparam_unset() {
  local key="$1"
  local target content new
  target=$(boot_config_path)
  content=$(_boot_config_read "$target")

  # Match an UNcommented dtparam=<key>= line. Comment it.
  if grep -qE "^[[:space:]]*dtparam=${key}=" <<< "$content"; then
    new=$(awk -v k="$key" '
      {
        if (match($0, "^[[:space:]]*dtparam=" k "=")) {
          print "#" $0
          next
        }
        print
      }
    ' <<< "$content")
    _boot_config_write_atomic "$target" <<< "$new"
  fi
}

# boot_config_overlay_add <owner> <line>
boot_config_overlay_add() {
  local owner="$1" line="$2"
  local target content new begin end existing
  target=$(boot_config_path)
  content=$(_boot_config_read "$target")
  begin="# === installicious:${owner} begin ==="
  end="# === installicious:${owner} end ==="

  # Already-present block? Compare its content; rewrite if differing.
  # Anchored regex (not substring) so a documentation comment that happens
  # to quote the fence text doesn't false-positive.
  if grep -qE "^# === installicious:${owner} begin ===$" <<< "$content"; then
    existing=$(awk -v b="$begin" -v e="$end" '
      $0 == b { inblk = 1; next }
      $0 == e { inblk = 0; next }
      inblk { print }
    ' <<< "$content")
    if [[ "$existing" == "$line" ]]; then
      return 0
    fi
    # Rewrite in place.
    new=$(awk -v b="$begin" -v e="$end" -v l="$line" '
      $0 == b { print; print l; skip=1; next }
      $0 == e { skip=0; print; next }
      skip { next }
      { print }
    ' <<< "$content")
    _boot_config_write_atomic "$target" <<< "$new"
    return 0
  fi

  # Fresh insert at end of file.
  new="$content"$'\n'"$begin"$'\n'"$line"$'\n'"$end"
  _boot_config_write_atomic "$target" <<< "$new"
}

# boot_config_overlay_remove <owner>
boot_config_overlay_remove() {
  local owner="$1"
  local target content new begin end
  target=$(boot_config_path)
  content=$(_boot_config_read "$target")
  begin="# === installicious:${owner} begin ==="
  end="# === installicious:${owner} end ==="
  # Anchored regex (not substring) — see boot_config_overlay_add.
  grep -qE "^# === installicious:${owner} begin ===$" <<< "$content" || return 0
  new=$(awk -v b="$begin" -v e="$end" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip { next }
    { print }
  ' <<< "$content")
  _boot_config_write_atomic "$target" <<< "$new"
}

# boot_config_overlay_has <owner> — rc=0 iff block present.
boot_config_overlay_has() {
  local owner="$1"
  local target content
  target=$(boot_config_path)
  content=$(_boot_config_read "$target")
  # Anchored regex (not substring) — see boot_config_overlay_add.
  grep -qE "^# === installicious:${owner} begin ===$" <<< "$content"
}
