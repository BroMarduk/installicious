#!/bin/bash

# lib/post_install.sh - Post-install action queue.
#
# Each installer can register two kinds of follow-up actions:
#
#   post_install_run "<shell command>"
#       Queued for execution at the end of the queue. Runs as the queue's
#       user (root, in normal usage). Deduped, so multiple installers asking
#       for the same command (e.g. `systemctl daemon-reload`) only run it
#       once. Use this for anything the framework can do automatically:
#       reloading services, regenerating caches, updating man-db, etc.
#
#   post_install_note "<id>" "<message>"
#       Queued for display at the end of the queue, as a one-line message
#       prefixed by the installer id. Use this for things that *require* the
#       user to act and can't be automated — e.g. `exec bash` to pick up
#       new aliases in their already-open interactive shell, or "open a new
#       SSH session" advice.
#
# Both kinds of entries persist in $PATH_STATE alongside the queue state, so
# they survive a reboot — an installer that registers a post_install_run
# before requesting a reboot will still see that command run after the resume
# completes (and any notes will still display).
#
# Lifecycle:
#   post_install_clear   - drop all pending entries (called at start of a
#                          fresh installicious run, NOT on resume)
#   post_install_apply   - run all queued commands, then print all queued
#                          notes, then clear both files. Called by
#                          scripts/options.sh and scripts/resume.sh when the
#                          queue completes (rc=0 or non-reboot error).
#
# Configuration consumed:
#   PATH_STATE  - directory for state files

_post_install_run_file()        { echo "${PATH_STATE:-state}/post-install-run.sh"; }
_post_install_run_skip_file()   { echo "${PATH_STATE:-state}/post-install-run-skip-after-reboot.sh"; }
_post_install_note_file()       { echo "${PATH_STATE:-state}/post-install-notes.txt"; }
_post_install_note_skip_file()  { echo "${PATH_STATE:-state}/post-install-notes-skip-after-reboot.txt"; }
_post_install_reload_flag()     { echo "${PATH_STATE:-state}/reload-shell"; }
_post_install_rebooted_flag()   { echo "${PATH_STATE:-state}/queue-rebooted.flag"; }

_post_install_ensure_dir() {
  local dir="${PATH_STATE:-state}"
  if [[ ! -d $dir ]]; then
    sudo mkdir -p "$dir" 2>/dev/null || mkdir -p "$dir" 2>/dev/null || return 1
  fi
}

# post_install_run <shell command>
# Queue a shell command to execute after the queue completes. Deduped against
# existing entries. Best-effort: returns 0 even if the file write fails.
post_install_run() {
  local cmd="$1"
  [[ -z $cmd ]] && return 0
  _post_install_ensure_dir
  local file
  file=$(_post_install_run_file)
  if [[ -f $file ]] && grep -qFx -- "$cmd" "$file" 2>/dev/null; then
    return 0
  fi
  echo "$cmd" | sudo tee -a "$file" >/dev/null 2>&1 \
    || echo "$cmd" >> "$file" 2>/dev/null \
    || return 1
}

# post_install_run_unless_rebooted <shell command>
# Like post_install_run, but if any reboot occurred during this queue
# (whether triggered by an earlier feature or a later one), the reboot
# already accomplished what this command does, so we skip it. Use for
# commands whose effect is reboot-subsumed:
#   - systemctl daemon-reload (reboot reloads all units anyway)
#   - update-grub             (reboot re-reads grub config)
#   - mandb -q                (cron will pick it up; reboot doesn't matter)
# Anything where running it after a reboot is wasted work belongs here.
# The reboot flag is set by the scheduler on EXIT_REBOOT and cleared at
# the next post_install_clear / post_install_apply.
post_install_run_unless_rebooted() {
  local cmd="$1"
  [[ -z $cmd ]] && return 0
  _post_install_ensure_dir
  local file
  file=$(_post_install_run_skip_file)
  if [[ -f $file ]] && grep -qFx -- "$cmd" "$file" 2>/dev/null; then
    return 0
  fi
  echo "$cmd" | sudo tee -a "$file" >/dev/null 2>&1 \
    || echo "$cmd" >> "$file" 2>/dev/null \
    || return 1
}

# post_install_mark_rebooted
# Called by the scheduler when an installer returns EXIT_REBOOT. Sets a
# flag that post_install_apply consults to skip the unless-rebooted
# command queue. Idempotent — multiple reboots in one queue still result
# in one flag.
post_install_mark_rebooted() {
  _post_install_ensure_dir
  local file
  file=$(_post_install_rebooted_flag)
  sudo touch "$file" 2>/dev/null || touch "$file" 2>/dev/null
}

# post_install_request_shell_reload
# Set the flag that the /etc/profile.d/installicious.sh wrapper function
# checks at the end of an installicious run. When the wrapper sees this
# flag (and the run didn't end with a reboot), it `exec bash -l` so the
# user's interactive shell picks up new aliases / prompt / etc. without
# them having to do it manually.
#
# A no-op when the user invokes installicious directly without the
# wrapper — in that case the existing post_install_note explaining
# `exec bash` is the user-visible fallback.
post_install_request_shell_reload() {
  _post_install_ensure_dir
  local file
  file=$(_post_install_reload_flag)
  sudo touch "$file" 2>/dev/null || touch "$file" 2>/dev/null
}

# post_install_cancel_shell_reload
# Drop the shell-reload flag. Called by request_reboot — a reboot already
# starts every shell fresh, so the wrapper's exec-bash would be redundant.
post_install_cancel_shell_reload() {
  local file
  file=$(_post_install_reload_flag)
  [[ -f $file ]] && (sudo rm -f "$file" 2>/dev/null || rm -f "$file" 2>/dev/null)
  return 0
}

# post_install_note <id> <message>
# Queue a "[id] message" line to display when the queue finishes. Deduped.
post_install_note() {
  local id="$1"
  local message="$2"
  [[ -z $id || -z $message ]] && return 0
  _post_install_ensure_dir
  local file line
  file=$(_post_install_note_file)
  line="[$id] $message"
  if [[ -f $file ]] && grep -qFx -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  echo "$line" | sudo tee -a "$file" >/dev/null 2>&1 \
    || echo "$line" >> "$file" 2>/dev/null \
    || return 1
}

# post_install_note_unless_rebooted <id> <message>
# Like post_install_note, but if any reboot occurred during this queue the
# note is dropped on the floor — the reboot already accomplished what the
# note would have nudged the user about (fresh shells get new aliases /
# prompt automatically, ssh-relogin advice is moot, etc.).
post_install_note_unless_rebooted() {
  local id="$1"
  local message="$2"
  [[ -z $id || -z $message ]] && return 0
  _post_install_ensure_dir
  local file line
  file=$(_post_install_note_skip_file)
  line="[$id] $message"
  if [[ -f $file ]] && grep -qFx -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  echo "$line" | sudo tee -a "$file" >/dev/null 2>&1 \
    || echo "$line" >> "$file" 2>/dev/null \
    || return 1
}

# post_install_apply - run queued commands, then print queued notes, clear.
post_install_apply() {
  local cmd_file skip_file note_file note_skip_file rebooted_flag rc=0
  cmd_file=$(_post_install_run_file)
  skip_file=$(_post_install_run_skip_file)
  note_file=$(_post_install_note_file)
  note_skip_file=$(_post_install_note_skip_file)
  rebooted_flag=$(_post_install_rebooted_flag)

  local rebooted=0
  [[ -f $rebooted_flag ]] && rebooted=1

  if [[ -s $cmd_file ]]; then
    echo
    echo "============================================================"
    echo "  Running post-install commands"
    echo "============================================================"
    while IFS= read -r cmd; do
      [[ -z $cmd ]] && continue
      echo "  > $cmd"
      bash -c "$cmd"
      local cmd_rc=$?
      if [[ $cmd_rc -ne 0 ]]; then
        echo "  (exit $cmd_rc)"
        rc=$cmd_rc
      fi
    done < "$cmd_file"
    echo "============================================================"
    sudo rm -f "$cmd_file" 2>/dev/null || rm -f "$cmd_file" 2>/dev/null
  fi

  if [[ -s $skip_file ]]; then
    if [[ $rebooted -eq 1 ]]; then
      local skipped
      skipped=$(wc -l < "$skip_file" 2>/dev/null | tr -d ' ')
      echo
      echo "============================================================"
      echo "  Skipping ${skipped} reboot-subsumed post-install command(s)"
      echo "  (a reboot during this queue already covered them)"
      echo "============================================================"
    else
      echo
      echo "============================================================"
      echo "  Running post-install commands (reboot-subsumable)"
      echo "============================================================"
      while IFS= read -r cmd; do
        [[ -z $cmd ]] && continue
        echo "  > $cmd"
        bash -c "$cmd"
        local cmd_rc=$?
        if [[ $cmd_rc -ne 0 ]]; then
          echo "  (exit $cmd_rc)"
          rc=$cmd_rc
        fi
      done < "$skip_file"
      echo "============================================================"
    fi
    sudo rm -f "$skip_file" 2>/dev/null || rm -f "$skip_file" 2>/dev/null
  fi

  # Merge always-show + reboot-subsumable note files for display. After a
  # reboot the skip-file's notes are dropped silently (no banner, no
  # mention); without a reboot they print alongside the regular notes
  # under the same "Post-install actions you need to take" header.
  local -a notes_to_show=()
  if [[ -s $note_file ]]; then
    notes_to_show+=("$note_file")
  fi
  if [[ -s $note_skip_file ]]; then
    if [[ $rebooted -eq 1 ]]; then
      log_info "Skipping $(wc -l < "$note_skip_file" | tr -d ' ') reboot-subsumed post-install note(s)."
    else
      notes_to_show+=("$note_skip_file")
    fi
  fi
  if (( ${#notes_to_show[@]} > 0 )); then
    echo
    echo "============================================================"
    echo "  Post-install actions you need to take"
    echo "============================================================"
    cat "${notes_to_show[@]}"
    echo "============================================================"
    echo
  fi
  [[ -f $note_file      ]] && (sudo rm -f "$note_file"      2>/dev/null || rm -f "$note_file"      2>/dev/null)
  [[ -f $note_skip_file ]] && (sudo rm -f "$note_skip_file" 2>/dev/null || rm -f "$note_skip_file" 2>/dev/null)

  # Drop the rebooted flag after we've used it. The next queue starts clean
  # (post_install_clear at the top of scripts/options.sh also clears it).
  [[ -f $rebooted_flag ]] && (sudo rm -f "$rebooted_flag" 2>/dev/null || rm -f "$rebooted_flag" 2>/dev/null)

  return $rc
}

# post_install_clear - drop all post-install state (commands, notes,
# reload-shell flag, reboot flag, unless-rebooted command file). Called at
# start of a fresh run so stale entries from a prior interrupted session
# don't carry over.
post_install_clear() {
  local cmd_file note_file note_skip_file reload_flag skip_file rebooted_flag
  cmd_file=$(_post_install_run_file)
  note_file=$(_post_install_note_file)
  note_skip_file=$(_post_install_note_skip_file)
  reload_flag=$(_post_install_reload_flag)
  skip_file=$(_post_install_run_skip_file)
  rebooted_flag=$(_post_install_rebooted_flag)
  [[ -f $cmd_file        ]] && (sudo rm -f "$cmd_file"        2>/dev/null || rm -f "$cmd_file"        2>/dev/null)
  [[ -f $note_file       ]] && (sudo rm -f "$note_file"       2>/dev/null || rm -f "$note_file"       2>/dev/null)
  [[ -f $note_skip_file  ]] && (sudo rm -f "$note_skip_file"  2>/dev/null || rm -f "$note_skip_file"  2>/dev/null)
  [[ -f $reload_flag     ]] && (sudo rm -f "$reload_flag"     2>/dev/null || rm -f "$reload_flag"     2>/dev/null)
  [[ -f $skip_file       ]] && (sudo rm -f "$skip_file"       2>/dev/null || rm -f "$skip_file"       2>/dev/null)
  [[ -f $rebooted_flag   ]] && (sudo rm -f "$rebooted_flag"   2>/dev/null || rm -f "$rebooted_flag"   2>/dev/null)
  return 0
}
