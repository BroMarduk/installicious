# /etc/profile.d/installicious.sh
#
# Defines an `installicious` shell function wrapper for the installicious
# entry script. Use it INSTEAD of `sudo bash installicious.sh` when you
# want shell-config changes (new aliases, prompt, etc.) to take effect
# immediately in your current shell.
#
# How it works:
#   1. The wrapper invokes /etc/installicious/installicious.sh under sudo.
#   2. When a feature changes shell config (e.g. the bash customizer),
#      it sets a flag at /etc/installicious/state/reload-shell.
#   3. When installicious exits (and didn't reboot), the wrapper sees the
#      flag, removes it, and `exec bash -l` so your interactive shell is
#      replaced with a fresh login bash that picks up the new config.
#
# When a reboot is requested (rc=255), the wrapper does NOT exec — the
# new login after the reboot starts with fresh config naturally.
#
# Non-interactive shells skip the function definition; only interactive
# logins get it.

# Skip for non-interactive shells (cron, scp, etc.).
[ -z "$PS1" ] && return 0
case $- in *i*) ;; *) return 0 ;; esac

# ---------------------------------------------------------------------------
# Resume transcript display
# ---------------------------------------------------------------------------
# When a queue ran across a reboot, the systemd unit ran resume.sh on /dev/tty1
# (the physical console). SSH'd users wouldn't see any of it. resume.sh now
# also writes a transcript to /etc/installicious/state/resume-transcript.log;
# we display it here on the user's first login.
#
#   - If resume is still running, tail -f the transcript bound to the
#     resume's PID — the user watches the rest of the run live in their
#     shell, control returns when the resume exits.
#   - If resume already finished, replay the transcript with cat. Colors,
#     [ OK ] markers, log lines all preserved.
#
# Per-user "already shown" marker (~/.installicious-transcript-shown) so
# multiple users on the same Pi each see it once, and reopening a shell
# after viewing doesn't replay.

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
      echo
      _installicious_pause_after_transcript
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
      _installicious_pause_after_transcript
      touch "$marker" 2>/dev/null
    fi
  fi
}

# Brief pause so the transcript stays on screen even if a verbose MOTD,
# bashrc banner, or fast prompt-paint would otherwise push it offscreen.
# 5-second timeout — user can press Enter to skip, or just ignore it.
# Reads from /dev/tty so it works even when stdin is redirected.
_installicious_pause_after_transcript() {
  if [ -t 0 ] || [ -t 1 ]; then
    read -t 5 -rp "Press Enter to continue (auto-continues in 5s)... " _ </dev/tty 2>/dev/null
    echo
  fi
}
# Defer the actual display until just before the user's first prompt via
# PROMPT_COMMAND. /etc/profile's default loop sources profile.d/*.sh BEFORE
# anything appended later in /etc/profile (notably feature-motd's MOTD
# launcher block) — running the transcript display inline here means MOTD
# would paint over it. PROMPT_COMMAND runs after /etc/profile finishes,
# after MOTD, right before the first prompt is drawn.
_installicious_pending_resume_check() {
  _installicious_show_resume_transcript
  # One-shot: drop ourselves from PROMPT_COMMAND so subsequent prompts
  # don't re-run, then garbage-collect the helpers.
  PROMPT_COMMAND="${PROMPT_COMMAND//_installicious_pending_resume_check;/}"
  PROMPT_COMMAND="${PROMPT_COMMAND//_installicious_pending_resume_check/}"
  unset -f _installicious_show_resume_transcript
  unset -f _installicious_pause_after_transcript
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
