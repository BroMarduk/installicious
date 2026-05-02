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

_post_install_run_file()  { echo "${PATH_STATE:-state}/post-install-run.sh"; }
_post_install_note_file() { echo "${PATH_STATE:-state}/post-install-notes.txt"; }

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

# post_install_apply - run queued commands, then print queued notes, clear.
post_install_apply() {
  local cmd_file note_file rc=0
  cmd_file=$(_post_install_run_file)
  note_file=$(_post_install_note_file)

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

  if [[ -s $note_file ]]; then
    echo
    echo "============================================================"
    echo "  Post-install actions you need to take"
    echo "============================================================"
    cat "$note_file"
    echo "============================================================"
    echo
    sudo rm -f "$note_file" 2>/dev/null || rm -f "$note_file" 2>/dev/null
  fi

  return $rc
}

# post_install_clear - drop both queues. Called at start of a fresh run so
# stale entries from a prior interrupted session don't carry over.
post_install_clear() {
  local cmd_file note_file
  cmd_file=$(_post_install_run_file)
  note_file=$(_post_install_note_file)
  [[ -f $cmd_file  ]] && (sudo rm -f "$cmd_file"  2>/dev/null || rm -f "$cmd_file"  2>/dev/null)
  [[ -f $note_file ]] && (sudo rm -f "$note_file" 2>/dev/null || rm -f "$note_file" 2>/dev/null)
  return 0
}
