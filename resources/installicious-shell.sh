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
  local svc="installicious-resume.service"
  local marker="$HOME/.installicious-transcript-shown"

  # Live attach if the resume service is currently running.
  if command -v systemctl >/dev/null 2>&1 \
     && systemctl is-active --quiet "$svc" 2>/dev/null; then
    local mainpid
    mainpid=$(systemctl show -p MainPID --value "$svc" 2>/dev/null)
    if [ -n "$mainpid" ] && [ "$mainpid" != "0" ] \
       && kill -0 "$mainpid" 2>/dev/null \
       && [ -f "$transcript" ]; then
      echo
      echo "============================================================"
      echo "  Installicious is still resuming after a reboot."
      echo "  Watching live; control returns when it completes..."
      echo "============================================================"
      # tail --pid exits when the watched process exits; -n +1 starts from
      # the top so we see anything we missed.
      tail -n +1 -f --pid="$mainpid" "$transcript" 2>/dev/null

      # tail --pid has a known race: when MainPID (the bash running
      # resume.sh) exits, tail may bail before tee finishes flushing
      # the final lines (in our case the Queue Summary block) into
      # the transcript file. Without this fallback the user sees the
      # whole resume except its summary, and the marker file below
      # then suppresses any replay on subsequent logins.
      #
      # Sleep briefly to let the tee subprocess drain, then re-print
      # the Queue Summary section unconditionally. Duplicates a few
      # lines in the common no-race case (acceptable), guarantees
      # the summary is visible in the racy case.
      sleep 0.3
      if grep -q '^  Queue Summary$' "$transcript" 2>/dev/null; then
        echo
        awk '/^  Queue Summary$/{flag=1} flag' "$transcript" 2>/dev/null
      fi
      echo
      touch "$marker" 2>/dev/null
      return 0
    fi
  fi

  # Replay completed transcript if this user hasn't seen it yet. Compare
  # mtimes so a transcript from THIS reboot is always shown once per user,
  # but already-seen transcripts don't replay every time you open a shell.
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
