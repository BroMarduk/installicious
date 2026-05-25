# /etc/profile.d/installicious.sh
#
# Sourced by /etc/profile for interactive login shells. Two responsibilities:
#
# 1. Resume-transcript display.
#    The systemd resume unit runs scripts/resume.sh on /dev/tty1 (the physical
#    console) after a reboot. SSH'd users couldn't see any of it. resume.sh
#    writes a transcript to /etc/installicious/state/resume-transcript.log;
#    we replay it (or live-tail it if the resume is still in flight) just
#    before the user's first prompt. A per-user marker
#    (~/.installicious-transcript-shown) ensures each user sees it once.
#
# 2. `installicious` shell-function wrapper.
#    Run `installicious` instead of `sudo bash installicious.sh` to get auto
#    shell reload at the end of a no-reboot run — when a feature flagged
#    /etc/installicious/state/reload-shell (e.g. the bash customizer added
#    new aliases), the wrapper `exec bash -l` so the user's interactive
#    shell picks up the new config without manual exec. Reboot exits (rc=255)
#    skip the exec — the new login after the reboot already gets fresh config.
#
# Non-interactive shells (cron, scp) skip everything below.

[ -z "$PS1" ] && return 0
case $- in *i*) ;; *) return 0 ;; esac

# ---------------------------------------------------------------------------
# Resume transcript display
# ---------------------------------------------------------------------------

_installicious_show_resume_transcript() {
  local transcript="/etc/installicious/state/resume-transcript.log"
  local queue="/etc/installicious/state/queue.sh"
  local marker="$HOME/.installicious-transcript-shown"

  # Queue in progress -> live-tail until queue.sh disappears.
  #
  # Why queue.sh and not `systemctl is-active` + MainPID:
  #   - Type=oneshot units have a race where MainPID briefly reads as 0
  #     while the service is technically "active", dropping us into the
  #     fall-through branch and showing the user a static snapshot
  #     ("output stops after a chunk") even though more output is on its
  #     way. queue.sh is the canonical "queue still has outstanding
  #     work" signal -- written by state_save / cleared by state_clear,
  #     persists across as many chained reboots as the install needs.
  #   - On a multi-reboot install (e.g. kernel update then a
  #     reboot-required feature), queue.sh survives between reboots; a
  #     reconnect after any reboot in the chain re-enters this loop and
  #     tails the new cycle's transcript naturally.
  #
  # `tail -F` (capital F) handles transcript truncation between chained
  # resume cycles (resume.sh truncates the transcript on each start).
  if [ -f "$queue" ]; then
    echo
    echo "============================================================"
    echo "  Installicious is resuming after a reboot."
    echo "  Watching live; control returns when the queue clears..."
    echo "============================================================"
    # Race guard: profile.d may fire before resume.sh has had time to
    # truncate / create the transcript. Wait briefly for it.
    local waited=0
    while [ ! -f "$transcript" ] && [ -f "$queue" ] && [ "$waited" -lt 30 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if [ -f "$transcript" ]; then
      tail -n +1 -F "$transcript" 2>/dev/null &
      local tpid=$!
      # Wait until installicious-resume.service deactivates. That's the
      # true end-of-run signal — `queue.sh` disappears mid-flight
      # (state_clear in scheduler_run_queue runs BEFORE
      # post_install_apply prints the queue summary), so polling
      # queue.sh used to kill the tail too early and the user never
      # saw the summary table. Polling the systemd unit instead
      # follows the full resume.sh lifetime; one extra second of grace
      # after deactivation flushes any trailing writes from the tee'd
      # transcript. queue.sh existence is still the gate that we ever
      # entered the loop in the first place — checked just above.
      while kill -0 "$tpid" 2>/dev/null; do
        if ! systemctl is-active --quiet installicious-resume.service 2>/dev/null; then
          sleep 1
          break
        fi
        sleep 1
      done
      kill "$tpid" 2>/dev/null
      wait "$tpid" 2>/dev/null
    fi
    echo
    echo "============================================================"
    echo "  Installicious resume complete."
    echo "============================================================"
    echo
    touch "$marker" 2>/dev/null
    return 0
  fi

  # No queue in progress -> replay completed transcript if this user
  # hasn't seen it yet. Compare mtimes so a transcript from THIS reboot
  # is always shown once per user, but already-seen transcripts don't
  # replay every time you open a shell.
  if [ -s "$transcript" ]; then
    if [ ! -f "$marker" ] || [ "$transcript" -nt "$marker" ]; then
      echo
      echo "============================================================"
      echo "  Installicious resume transcript (last reboot):"
      echo "============================================================"
      cat "$transcript"
      echo "============================================================"
      echo
      touch "$marker" 2>/dev/null
    fi
  fi
}
# Defer the actual display until just before the user's first prompt via
# PROMPT_COMMAND. /etc/profile sources profile.d/*.sh BEFORE anything
# appended later in /etc/profile itself (notably feature-motd's MOTD
# launcher block), so an inline display here would get painted over.
# PROMPT_COMMAND fires after /etc/profile finishes — after MOTD, after
# everything — so the transcript ends up immediately above the prompt.
_installicious_pending_resume_check() {
  _installicious_show_resume_transcript
  # One-shot: drop ourselves from PROMPT_COMMAND so subsequent prompts
  # don't re-run, then garbage-collect the helpers.
  PROMPT_COMMAND="${PROMPT_COMMAND//_installicious_pending_resume_check;/}"
  PROMPT_COMMAND="${PROMPT_COMMAND//_installicious_pending_resume_check/}"
  unset -f _installicious_show_resume_transcript
  unset -f _installicious_pending_resume_check
}
PROMPT_COMMAND="_installicious_pending_resume_check;${PROMPT_COMMAND:-}"

# ---------------------------------------------------------------------------
# `installicious` shell wrapper function
# ---------------------------------------------------------------------------

installicious() {
  local script="/etc/installicious/installicious.sh"
  if [ ! -f "$script" ]; then
    echo "installicious: $script not found" >&2
    return 127
  fi
  sudo bash "$script" "$@"
  local rc=$?

  local reload_flag="/etc/installicious/state/reload-shell"
  if [ $rc -ne 255 ] && [ -f "$reload_flag" ]; then
    sudo rm -f "$reload_flag"
    echo
    echo "[installicious] Reloading shell to pick up the new config..."
    exec bash -l
  fi
  return $rc
}
