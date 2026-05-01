#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Debian/Ubuntu Bash configuration helper
#
# Modes:
#   --all      (default) configure both root + user  [REQUIRES SUDO/ROOT]
#   --root     configure only root                   [REQUIRES SUDO/ROOT]
#   --user     configure only user
#
# Options:
#   --target-user=NAME   set which user to configure (default = SUDO_USER or USER)
#   --no-backup          skip creating per-file .bak files
#   --backup-file=PATH   create ONE tar.gz archive at PATH containing backups for targeted files
#   --restore            restore a backup (interactive if >1)  [mutually exclusive w/ --restore-file]
#   --auto-restore       restore the newest backup automatically (no prompt)  [mutually exclusive w/ --restore-file]
#   --restore-file=PATH  restore directly from the given tar.gz archive       [mutually exclusive w/ --restore/--auto-restore]
#   --auto-reload        auto exec bash if user account was updated (non-sudo only)
#   --status             show what would be affected; combine w/ --restore/--auto-restore/--restore-file for dry-run
#   --json               print --status output as JSON (only valid with --status)
# ==============================================================================

MODE="all"
TARGET_USER="${SUDO_USER:-${USER:-}}"
EXPLICIT_TARGET=0
DO_BACKUP=1                  # controls per-file .bak (disabled if --backup-file is set)
BACKUP_FILE=""               # single archive path for all targeted files
DO_RESTORE=0
DO_AUTO_RESTORE=0
RESTORE_FILE=""              # explicit archive to restore from
DO_AUTO_RELOAD=0
DO_STATUS=0
DO_JSON=0
USER_UPDATED=0

for arg in "$@"; do
  case "$arg" in
    --all)  MODE="all" ;;
    --root) MODE="root" ;;
    --user) MODE="user" ;;
    --target-user=*)
      TARGET_USER="${arg#*=}"
      EXPLICIT_TARGET=1
      ;;
    --no-backup) DO_BACKUP=0 ;;
    --backup-file=*)
      BACKUP_FILE="${arg#*=}"
      ;;
    --restore) DO_RESTORE=1 ;;
    --auto-restore) DO_AUTO_RESTORE=1 ;;
    --restore-file=*)
      RESTORE_FILE="${arg#*=}"
      ;;
    --auto-reload) DO_AUTO_RELOAD=1 ;;
    --status) DO_STATUS=1 ;;
    --json) DO_JSON=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage:
  sudo ./setup-bash.sh [--all|--root|--user] [--target-user=NAME]
                        [--no-backup | --backup-file=/path/backup.tar.gz]
  sudo ./setup-bash.sh --restore [--all|--root|--user] [--target-user=NAME]
  sudo ./setup-bash.sh --auto-restore [--all|--root|--user] [--target-user=NAME]
  sudo ./setup-bash.sh --restore-file=/path/backup.tar.gz [--all|--root|--user] [--target-user=NAME]
  ./setup-bash.sh --status [--all|--root|--user] [--target-user=NAME]
                  [--restore | --auto-restore | --restore-file=/path/backup.tar.gz] [--json]

Notes:
  --all strictly requires sudo/root.
  From a root shell (no SUDO_USER):
    - --all requires --target-user=NAME
    - --user requires --target-user=NAME
  --restore is interactive if multiple backups exist; auto if only one.
  --auto-restore always picks the newest backup without prompting.
  --restore-file restores from the specific archive; cannot be combined with --restore/--auto-restore.
  --backup-file creates ONE tar.gz archive containing all targeted files' backups; incompatible with --no-backup.
  --auto-reload only works for non-sudo user updates; it runs exec bash automatically.
  --status shows what would be affected; with restore flags it lists backup candidates (dry-run).
  --json is only valid with --status.

Examples:
  sudo ./setup-bash.sh --all --target-user=dan
  ./setup-bash.sh --user --auto-reload
  sudo ./setup-bash.sh --restore --all --target-user=alice
  sudo ./setup-bash.sh --restore-file=/safe/backups/bashrc-2025-08-31.tar.gz --all --target-user=dan
  sudo ./setup-bash.sh --status --all --target-user=dan --auto-restore --json
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# ----------------------------- Arg validation ---------------------------------
# Ensure TARGET_USER is resolvable when it will actually be needed.
if [[ -z "$TARGET_USER" ]]; then
  # Only hard-fail here if we definitely need a user (any mode touching the user side).
  if [[ "$MODE" == "user" || "$MODE" == "all" ]]; then
    echo "[ERROR] Could not determine target user (SUDO_USER and USER are both unset). Use --target-user=NAME." >&2
    exit 2
  fi
fi

# restore-file conflicts with the discover/choose restore modes
if [[ -n "$RESTORE_FILE" && ( $DO_RESTORE -eq 1 || $DO_AUTO_RESTORE -eq 1 ) ]]; then
  echo "--restore-file cannot be combined with --restore or --auto-restore." >&2
  exit 2
fi
# backup-file conflicts with no-backup
if [[ -n "$BACKUP_FILE" && $DO_BACKUP -eq 0 ]]; then
  echo "--backup-file cannot be used with --no-backup." >&2
  exit 2
fi
# --json only valid with --status
if [[ $DO_JSON -eq 1 && $DO_STATUS -eq 0 ]]; then
  echo "--json is only valid with --status." >&2
  exit 2
fi

timestamp() { date +%Y%m%d-%H%M%S; }

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Resolve ownership spec for chown. Uses user:group if the user's primary group
# resolves, otherwise just the user.
owner_spec() {
  local user="$1"
  local grp
  if grp="$(id -gn "$user" 2>/dev/null)" && [[ -n "$grp" ]]; then
    printf '%s:%s' "$user" "$grp"
  else
    printf '%s' "$user"
  fi
}

ensure_file_exists() {
  local file="$1" owner="$2"
  if [[ ! -f "$file" ]]; then
    mkdir -p "$(dirname "$file")"
    : > "$file"
    [[ -n "$owner" ]] && chown "$owner" "$file" || true
  fi
}

# ----------------------------- Backup helpers --------------------------------
# Standard per-file .bak (only used if BACKUP_FILE is not set)
backup_once() {
  local file="$1" owner="$2"
  local bak="$file.$(timestamp).bak"
  cp -a "$file" "$bak"
  [[ -n "$owner" ]] && chown "$owner" "$bak" || true
  echo "Backup created: $bak"
}

# Create a single tar.gz archive for all targeted files that exist
create_single_backup_archive() {
  local archive="$1"; shift
  local files_to_backup=("$@")

  # Validate path & permissions
  local dirpath; dirpath="$(dirname "$archive")"
  if [[ ! -d "$dirpath" ]]; then
    echo "[ERROR] Backup directory does not exist: $dirpath" >&2
    exit 1
  fi
  if [[ ! -w "$dirpath" ]]; then
    echo "[ERROR] No write permission to backup directory: $dirpath" >&2
    exit 1
  fi
  if [[ -e "$archive" ]]; then
    echo "[ERROR] Backup file already exists: $archive" >&2
    exit 1
  fi

  # Stage files into a temp dir with deterministic names
  local tmpdir; tmpdir="$(mktemp -d)"
  local staged=0
  for spec in "${files_to_backup[@]}"; do
    # spec format: LABEL|ABSOLUTE_PATH
    local label="${spec%%|*}"
    local path="${spec#*|}"
    if [[ -f "$path" ]]; then
      case "$label" in
        root) cp -a "$path" "$tmpdir/root.bashrc" ;;
        user) cp -a "$path" "$tmpdir/user-$TARGET_USER.bashrc" ;;
      esac
      staged=1
    fi
  done

  # It's OK if some files don't exist yet; we still write the archive if any were staged
  if [[ $staged -eq 1 ]]; then
    tar -C "$tmpdir" -czf "$archive" .
    echo "Created backup archive: $archive"
  else
    # Create an empty archive to reflect intent; or choose to fail.
    # Here we choose to create an empty archive so there's a clear artifact.
    tar -C "$tmpdir" -czf "$archive" .
    echo "Created backup archive (no files existed yet): $archive"
  fi
  rm -rf "$tmpdir"
}

# Restore from an explicit archive (maps files by staged names)
restore_from_archive() {
  local archive="$1" root_target="$2" user_target="$3"

  # Validations
  if [[ ! -r "$archive" ]]; then
    echo "[ERROR] Restore file is not readable: $archive" >&2
    exit 1
  fi

  local tmpdir; tmpdir="$(mktemp -d)"
  tar -C "$tmpdir" -xzf "$archive" || { echo "[ERROR] Failed to extract archive: $archive" >&2; rm -rf "$tmpdir"; exit 1; }

  local restored_any=0

  if [[ -n "$root_target" && -f "$tmpdir/root.bashrc" ]]; then
    cp -a "$tmpdir/root.bashrc" "$root_target"
    echo "Restored $root_target from archive"
    restored_any=1
  fi

  if [[ -n "$user_target" && -f "$tmpdir/user-$TARGET_USER.bashrc" ]]; then
    cp -a "$tmpdir/user-$TARGET_USER.bashrc" "$user_target"
    echo "Restored $user_target from archive"
    restored_any=1
  fi

  if [[ $restored_any -eq 0 ]]; then
    echo "[WARN] Archive did not contain matching entries for selected mode/target." >&2
  fi

  rm -rf "$tmpdir"
}

# Restore the newest .bak for a given file (no prompt). Returns 0 if nothing to do.
restore_latest() {
  local file="$1"
  local latest
  latest="$(ls -t -- "$file".*.bak 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest" ]]; then
    echo "[WARN] No backups found for $file" >&2
    return 0
  fi
  cp -a "$latest" "$file"
  echo "Restored $file from $latest"
}

# Restore a .bak for a given file. If only one exists, pick it. Otherwise prompt.
restore_choose() {
  local file="$1"
  local baks=()
  mapfile -t baks < <(ls -t -- "$file".*.bak 2>/dev/null || true)

  if [[ ${#baks[@]} -eq 0 ]]; then
    echo "[WARN] No backups found for $file" >&2
    return 0
  fi
  if [[ ${#baks[@]} -eq 1 ]]; then
    cp -a "${baks[0]}" "$file"
    echo "Restored $file from ${baks[0]}"
    return 0
  fi

  echo "Backups available for $file:"
  local i=1
  for b in "${baks[@]}"; do
    printf '  [%d] %s\n' "$i" "$b"
    ((i++))
  done

  local choice
  read -rp "Choose backup [1-${#baks[@]}] (or blank to skip): " choice
  if [[ -z "$choice" ]]; then
    echo "Skipped restore for $file"
    return 0
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#baks[@]} )); then
    echo "[ERROR] Invalid choice: $choice" >&2
    return 1
  fi
  cp -a "${baks[choice-1]}" "$file"
  echo "Restored $file from ${baks[choice-1]}"
}

# ----------------------------- Content writers -------------------------------
# Strip any existing managed block (matched by full-line equality, leading/trailing
# whitespace tolerated via awk) and append the new block from stdin.
ensure_block_stdin() {
  local file="$1" start="$2" end="$3"
  # Use a full-line anchored fixed-string check to match awk's exact-line logic.
  if grep -qxF "$start" "$file"; then
    awk -v s="$start" -v e="$end" '
      BEGIN {inblk=0}
      $0==s {inblk=1; next}
      $0==e {inblk=0; next}
      inblk==0 {print}
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
  {
    echo "$start"
    cat
    echo "$end"
  } >> "$file"
}

# ----------------------------- Configure root --------------------------------
configure_root() {
  local ROOT_RC="/root/.bashrc"
  local OWNER
  OWNER="$(owner_spec root)"
  ensure_file_exists "$ROOT_RC" "$OWNER"
  if [[ -z "$BACKUP_FILE" && $DO_BACKUP -eq 1 ]]; then
    backup_once "$ROOT_RC" "$OWNER"
  fi

  ensure_block_stdin "$ROOT_RC" "# ----- HW ROOT PS1 (managed) -----" "# ----- END HW ROOT PS1 -----" <<'EOF'
# Root: red username, blue working dir
PS1='${debian_chroot:+($debian_chroot)}\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF

  ensure_block_stdin "$ROOT_RC" "# ----- HW ROOT COLOR/LISTING BLOCK (managed) -----" "# ----- END HW ROOT COLOR/LISTING BLOCK -----" <<'EOF'
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

  chown "$OWNER" "$ROOT_RC"
  echo "Updated: $ROOT_RC"
}

# ----------------------------- Configure user --------------------------------
configure_user() {
  local HOME_DIR
  HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
  if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
    echo "Could not determine home for user '$TARGET_USER'." >&2
    exit 1
  fi
  local USER_RC="$HOME_DIR/.bashrc"
  local OWNER
  OWNER="$(owner_spec "$TARGET_USER")"

  ensure_file_exists "$USER_RC" "$OWNER"
  if [[ -z "$BACKUP_FILE" && $DO_BACKUP -eq 1 ]]; then
    backup_once "$USER_RC" "$OWNER"
  fi

  ensure_block_stdin "$USER_RC" "# ----- HW USER COLOR/ALIAS BLOCK (managed) -----" "# ----- END HW USER COLOR/ALIAS BLOCK -----" <<'EOF'
force_color_prompt=yes

alias ls='ls --color=auto'
alias dir='ls -la --color=auto'
alias vdir='vdir --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# enable aliases for sudo (trailing space is important)
alias sudo='sudo '
EOF

  chown "$OWNER" "$USER_RC"
  echo "Updated: $USER_RC (user: $TARGET_USER)"
  USER_UPDATED=1
}

# ----------------------------- Status mode -----------------------------------
if [[ $DO_STATUS -eq 1 ]]; then
  DRY_RESTORE=0
  [[ $DO_RESTORE -eq 1 || $DO_AUTO_RESTORE -eq 1 || -n "$RESTORE_FILE" ]] && DRY_RESTORE=1

  # resolve files per mode & safety rules
  case "$MODE" in
    root)
      [[ $EUID -eq 0 ]] || { echo "[ERROR] --status --root requires sudo/root." >&2; exit 1; }
      ROOT_FILE="/root/.bashrc"
      ;;
    user)
      if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "[ERROR] --status --user from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "[ERROR] Could not determine home for $TARGET_USER" >&2; exit 1; }
      USER_FILE="$HOME_DIR/.bashrc"
      ;;
    all)
      [[ $EUID -eq 0 ]] || { echo "[ERROR] --status --all requires sudo/root." >&2; exit 1; }
      if [[ -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "[ERROR] --status --all from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      ROOT_FILE="/root/.bashrc"
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "[ERROR] Could not determine home for $TARGET_USER" >&2; exit 1; }
      USER_FILE="$HOME_DIR/.bashrc"
      ;;
  esac

  # Helper to list backups in filesystem
  list_fs_backups() {
    local path="$1"
    ls -t -- "$path".*.bak 2>/dev/null || true
  }

  if [[ $DO_JSON -eq 1 ]]; then
    printf '{'
    printf '"mode":"%s",' "$(json_escape "$MODE")"
    printf '"dry_restore":%s,' "$([[ $DRY_RESTORE -eq 1 ]] && echo true || echo false)"
    printf '"auto_restore":%s,' "$([[ $DO_AUTO_RESTORE -eq 1 ]] && echo true || echo false)"
    printf '"restore_file":"%s",' "$(json_escape "$RESTORE_FILE")"
    printf '"backup_file":"%s",' "$(json_escape "$BACKUP_FILE")"
    printf '"targets":['
    first=1

    if [[ -n "${ROOT_FILE:-}" ]]; then
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{'
      printf '"label":"root","file":"%s","exists":%s' "$(json_escape "$ROOT_FILE")" "$([[ -f "$ROOT_FILE" ]] && echo true || echo false)"
      if [[ $DRY_RESTORE -eq 1 ]]; then
        printf ',"candidates":['
        if [[ -n "$RESTORE_FILE" ]]; then
          # show archive presence
          printf '{"type":"archive","path":"%s"}' "$(json_escape "$RESTORE_FILE")"
        else
          sb_first=1
          while IFS= read -r b; do
            [[ -n "$b" ]] || continue
            [[ $sb_first -eq 1 ]] || printf ','
            sb_first=0
            ts="${b##*.bashrc.}"; ts="${ts%.bak}"
            printf '{"type":"file","path":"%s","timestamp":"%s"}' "$(json_escape "$b")" "$(json_escape "$ts")"
          done < <(list_fs_backups "$ROOT_FILE")
          if [[ $sb_first -eq 1 ]]; then :; fi
        fi
        printf ']'
      fi
      printf '}'
    fi

    if [[ -n "${USER_FILE:-}" ]]; then
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{'
      printf '"label":"user","user":"%s","file":"%s","exists":%s' "$(json_escape "$TARGET_USER")" "$(json_escape "$USER_FILE")" "$([[ -f "$USER_FILE" ]] && echo true || echo false)"
      if [[ $DRY_RESTORE -eq 1 ]]; then
        printf ',"candidates":['
        if [[ -n "$RESTORE_FILE" ]]; then
          printf '{"type":"archive","path":"%s"}' "$(json_escape "$RESTORE_FILE")"
        else
          sb_first=1
          while IFS= read -r b; do
            [[ -n "$b" ]] || continue
            [[ $sb_first -eq 1 ]] || printf ','
            sb_first=0
            ts="${b##*.bashrc.}"; ts="${ts%.bak}"
            printf '{"type":"file","path":"%s","timestamp":"%s","auto_choice":%s}' "$(json_escape "$b")" "$(json_escape "$ts")" "$([[ $DO_AUTO_RESTORE -eq 1 && $sb_first -eq 1 ]] && echo true || echo false)"
          done < <(list_fs_backups "$USER_FILE")
          if [[ $sb_first -eq 1 ]]; then :; fi
        fi
        printf ']'
      fi
      printf '}'
    fi

    printf ']}\n'
    exit 0
  else
    echo "[STATUS] Mode: $MODE"
    [[ -n "$BACKUP_FILE" ]] && echo "  (Backup archive would be: $BACKUP_FILE)"
    [[ -n "$RESTORE_FILE" ]] && echo "  (Restore from archive: $RESTORE_FILE)"

    show_target() {
      local label="$1" file="$2"
      if [[ $DRY_RESTORE -eq 1 ]]; then
        echo "  $label: $file"
        if [[ -n "$RESTORE_FILE" ]]; then
          echo "    restore-file: $RESTORE_FILE"
        else
          mapfile -t BAKS < <(list_fs_backups "$file")
          if [[ ${#BAKS[@]} -eq 0 ]]; then
            echo "    (no .bak files found)"
          else
            local i=1
            for b in "${BAKS[@]}"; do
              ts="${b##*.bashrc.}"; ts="${ts%.bak}"
              printf '    [%d] %s (timestamp: %s)\n' "$i" "$b" "$ts"
              ((i++))
            done
            if [[ $DO_AUTO_RESTORE -eq 1 ]]; then
              echo "    (auto-restore would pick: ${BAKS[0]})"
            else
              echo "    (restore would prompt to choose)"
            fi
          fi
        fi
      else
        echo "  $label: $file $( [[ -f "$file" ]] && echo '(exists)' || echo '(will be created)' )"
      fi
    }

    [[ -n "${ROOT_FILE:-}" ]] && show_target "Root" "$ROOT_FILE"
    [[ -n "${USER_FILE:-}" ]] && show_target "User ($TARGET_USER)" "$USER_FILE"
    exit 0
  fi
fi

# ----------------------------- Restore flows ---------------------------------
if [[ -n "$RESTORE_FILE" ]]; then
  # explicit archive restore
  case "$MODE" in
    root)
      [[ $EUID -eq 0 ]] || { echo "--restore-file --root requires sudo/root." >&2; exit 1; }
      restore_from_archive "$RESTORE_FILE" "/root/.bashrc" ""
      ;;
    user)
      if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "--restore-file --user from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "No home for $TARGET_USER" >&2; exit 1; }
      restore_from_archive "$RESTORE_FILE" "" "$HOME_DIR/.bashrc"
      ;;
    all)
      [[ $EUID -eq 0 ]] || { echo "--restore-file --all requires sudo/root." >&2; exit 1; }
      if [[ -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "--restore-file --all from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "No home for $TARGET_USER" >&2; exit 1; }
      restore_from_archive "$RESTORE_FILE" "/root/.bashrc" "$HOME_DIR/.bashrc"
      ;;
  esac
  exit 0
fi

if [[ $DO_RESTORE -eq 1 || $DO_AUTO_RESTORE -eq 1 ]]; then
  RESTORE_FN="restore_choose"
  [[ $DO_AUTO_RESTORE -eq 1 ]] && RESTORE_FN="restore_latest"

  case "$MODE" in
    root)
      [[ $EUID -eq 0 ]] || { echo "--restore/--auto-restore --root requires sudo/root." >&2; exit 1; }
      $RESTORE_FN "/root/.bashrc"
      ;;
    user)
      if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "--restore/--auto-restore --user from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "No home for $TARGET_USER" >&2; exit 1; }
      $RESTORE_FN "$HOME_DIR/.bashrc"
      ;;
    all)
      [[ $EUID -eq 0 ]] || { echo "--restore/--auto-restore --all requires sudo/root." >&2; exit 1; }
      if [[ -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "--restore/--auto-restore --all from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      $RESTORE_FN "/root/.bashrc"
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] && $RESTORE_FN "$HOME_DIR/.bashrc" || echo "No home for $TARGET_USER"
      ;;
  esac
  exit 0
fi

# ----------------------------- Pre-backup (archive) --------------------------
# If BACKUP_FILE is set, build the single archive BEFORE modifying
if [[ -n "$BACKUP_FILE" ]]; then
  # resolve targets like in configure flows
  root_path=""
  user_path=""
  case "$MODE" in
    root)
      [[ $EUID -eq 0 ]] || { echo "--root requires sudo/root." >&2; exit 1; }
      root_path="/root/.bashrc"
      ;;
    user)
      if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "--user from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "No home for $TARGET_USER" >&2; exit 1; }
      user_path="$HOME_DIR/.bashrc"
      ;;
    all)
      [[ $EUID -eq 0 ]] || { echo "--all requires sudo/root." >&2; exit 1; }
      if [[ -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
        echo "--all from a root shell requires --target-user=NAME" >&2
        exit 1
      fi
      root_path="/root/.bashrc"
      HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
      [[ -n "$HOME_DIR" ]] || { echo "No home for $TARGET_USER" >&2; exit 1; }
      user_path="$HOME_DIR/.bashrc"
      ;;
  esac

  declare -a specs=()
  [[ -n "$root_path" ]] && specs+=("root|$root_path")
  [[ -n "$user_path" ]] && specs+=("user|$user_path")
  create_single_backup_archive "$BACKUP_FILE" "${specs[@]}"
  # Disable per-file backups since we just archived
  DO_BACKUP=0
fi

# ----------------------------- Configure flows -------------------------------
case "$MODE" in
  root)
    [[ $EUID -eq 0 ]] || { echo "--root requires sudo/root." >&2; exit 1; }
    configure_root
    ;;
  user)
    if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
      echo "--user from a root shell requires --target-user=NAME" >&2
      exit 1
    fi
    configure_user
    ;;
  all)
    [[ $EUID -eq 0 ]] || { echo "--all requires sudo/root." >&2; exit 1; }
    if [[ -z "${SUDO_USER:-}" && $EXPLICIT_TARGET -eq 0 ]]; then
      echo "--all from a root shell requires --target-user=NAME" >&2
      exit 1
    fi
    configure_root
    configure_user
    ;;
esac

# ----------------------------- Post-run messages -----------------------------
echo
if [[ $USER_UPDATED -eq 1 ]]; then
  if [[ $DO_AUTO_RELOAD -eq 1 && $EUID -ne 0 && "$TARGET_USER" == "$USER" ]]; then
    echo "[INFO] User config updated. Shell has been reloaded automatically."
    exec bash
  else
    echo "[INFO] User config updated. Run 'exec bash' or open a new terminal to apply changes."
  fi
fi
if [[ "$MODE" == "root" || "$MODE" == "all" ]]; then
  echo "[INFO] Root config updated. Run 'sudo -i' to see changes."
fi
