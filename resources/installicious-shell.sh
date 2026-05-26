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

# _installicious_resume_running — primary "is the resume still in flight"
# signal used by the live-tail loop below. Order of trust:
#   1. resume.sh writes /etc/installicious/state/resume.pid at start and
#      removes it on exit (EXIT trap). PID file exists AND `kill -0 $pid`
#      succeeds -> still running. This is independent of systemd state.
#   2. Fallback: `systemctl is-active installicious-resume.service`. Used
#      only when the PID file is absent (legacy installs without the
#      sentinel, or a transient race during resume.sh startup).
# Prior versions relied on `systemctl is-active` alone or on `kill -0`
# of `tail -F`'s PID; both could false-positive "done" mid-resume — a
# daemon-reload triggered by an apt postinst would briefly flip is-active
# to inactive, and `tail -F` itself could die from OOM / SIGPIPE / tty
# hiccups during long apt installs. The PID-file approach removes both
# failure modes.
_installicious_resume_running() {
  local pid_file="/etc/installicious/state/resume.pid"
  local pid
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    return 1
  fi
  systemctl is-active --quiet installicious-resume.service 2>/dev/null
}

_installicious_show_resume_transcript() {
  local transcript="/etc/installicious/state/resume-transcript.log"
  local queue="/etc/installicious/state/queue.sh"
  local marker="$HOME/.installicious-transcript-shown"

  # Queue in progress -> live-tail until resume.sh exits.
  #
  # Gate: queue.sh exists. Set by state_save (scheduler_run_queue) when
  # the first installer in a queue starts; removed by state_clear when
  # the queue empties. Survives chained reboots, so a reconnect after
  # any reboot in the chain re-enters this loop and tails the new
  # cycle's transcript naturally. queue.sh is removed mid-flight
  # (state_clear runs BEFORE post_install_apply prints the queue
  # summary), so it's only used as the entry gate — the loop body uses
  # _installicious_resume_running (PID-file based) for the actual
  # liveness check so we still see the trailing summary.
  #
  # `tail -F` handles transcript truncation between chained resume
  # cycles (resume.sh truncates the transcript on each start).
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
      # Loop until _installicious_resume_running reports done (PID file
      # gone OR process dead). If tail itself dies mid-flight (OOM,
      # SIGPIPE, IO error during a long apt install), respawn it with
      # `-n 0` so the user doesn't re-see the backlog they already
      # watched — a small gap of missed lines beats a false "complete"
      # banner. The 1-second post-loop sleep gives the tee subshell a
      # chance to flush trailing writes before we kill tail.
      while _installicious_resume_running; do
        if ! kill -0 "$tpid" 2>/dev/null; then
          tail -n 0 -F "$transcript" 2>/dev/null &
          tpid=$!
        fi
        sleep 1
      done
      sleep 1
      kill "$tpid" 2>/dev/null
      wait "$tpid" 2>/dev/null
    fi
    echo
    echo "============================================================"
    # Differentiate clean-completion from interruption. resume.sh's
    # exit only means "this cycle's bash exited" — on a multi-reboot
    # install the queue continues in a fresh cycle after the reboot.
    # state_clear (in scheduler_run_queue) removes queue.sh ONLY when
    # the queue actually empties; an installer returning 255 (reboot
    # requested) leaves queue.sh in place so the resume can pick up
    # from the right cursor after reboot. So queue.sh's continued
    # existence is the canonical "more to do" signal here.
    if [ -f "$queue" ]; then
      echo "  Resume paused — queue still has work."
      echo "  Reconnect after the reboot to watch the continuation."
    else
      echo "  Installicious resume complete."
    fi
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
