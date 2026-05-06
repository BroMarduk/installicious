#!/bin/bash

# lib/reboot.sh - Reboot/resume helper.
#
# request_reboot saves a "reboot-pending" queue state, enables the
# installicious-resume.service systemd unit (so we resume on next boot), and
# triggers a reboot. Replaces the legacy rc.local-injected resume mechanism.
#
# This is intentionally just the request side. The receive side is the
# systemd unit + scripts/resume.sh — which loads state and resumes the queue.
#
# Usage from inside an installer that needs a reboot:
#   source lib/reboot.sh
#   request_reboot "rconf locale change"  "rconf"   # reason, trigger-id
#   exit $EXIT_REBOOT                                  # 255
#
# Configuration consumed (must be in scope):
#   PATH_STATE - state directory (queue.sh lives here)
#
# Requires lib/state.sh to be sourced first. lib/log.sh recommended for
# warning output.

EXIT_REBOOT=255
RESUME_SERVICE_NAME="${RESUME_SERVICE_NAME:-installicious-resume.service}"
RESUME_SERVICE_SRC="${RESUME_SERVICE_SRC:-${PATH_RESOURCES:-resources}/installicious-resume.service}"
RESUME_SERVICE_DST="${RESUME_SERVICE_DST:-/etc/systemd/system/${RESUME_SERVICE_NAME}}"

# _resume_service_install — copy the unit file into /etc/systemd/system/ so
# `systemctl enable` actually finds it. systemd looks at /etc/systemd/system/
# and /lib/systemd/system/, not at our checkout's resources/ dir. Idempotent:
# copies if missing or out-of-date, otherwise no-op. setup.sh also drops the
# unit at install time; this is the safety net for a fresh wget+tar that
# skipped setup.sh.
_resume_service_install() {
  if [[ ! -f $RESUME_SERVICE_SRC ]]; then
    echo "_resume_service_install: source unit not found at $RESUME_SERVICE_SRC" >&2
    return 1
  fi
  if [[ -f $RESUME_SERVICE_DST ]] \
     && cmp -s "$RESUME_SERVICE_SRC" "$RESUME_SERVICE_DST" 2>/dev/null; then
    return 0
  fi
  if ! sudo install -m 0644 "$RESUME_SERVICE_SRC" "$RESUME_SERVICE_DST" 2>/dev/null; then
    echo "_resume_service_install: failed to copy unit to $RESUME_SERVICE_DST" >&2
    return 1
  fi
  sudo systemctl daemon-reload 2>/dev/null || true
  return 0
}

# request_reboot <reason> <trigger>
# Save state, enable resume unit, trigger reboot. Does NOT exit; caller is
# responsible for exiting with $EXIT_REBOOT so the scheduler picks up the
# signal. (We don't exit here so the caller can do its own cleanup first.)
request_reboot() {
  local reason="${1:-unspecified}"
  local trigger="${2:-unknown}"

  if ! declare -F state_save_reboot >/dev/null; then
    echo "request_reboot: lib/state.sh not loaded" >&2
    return 1
  fi

  # The scheduler is expected to update the cursor before calling us, so the
  # state file should already reflect the right cursor. We just flip it to
  # reboot-pending with our reason/trigger.
  state_load 2>/dev/null
  local cursor="${II_QUEUE_CURSOR:-0}"
  state_save_reboot "$cursor" "$reason" "$trigger"

  # A pending shell-reload is already covered by the post-reboot login —
  # cancel the flag so the wrapper function doesn't double-up later.
  if declare -F post_install_cancel_shell_reload >/dev/null; then
    post_install_cancel_shell_reload
  fi

  # Best-effort enable the resume service. systemctl exists on all our target
  # OSes (Bookworm/Trixie and forward) but be defensive. Install the unit
  # file first so `systemctl enable` finds something to enable.
  if command -v systemctl >/dev/null 2>&1; then
    _resume_service_install
    if ! sudo systemctl enable "$RESUME_SERVICE_NAME" 2>/dev/null; then
      echo "request_reboot: failed to enable $RESUME_SERVICE_NAME (continuing)" >&2
    fi
  else
    echo "request_reboot: systemctl not available; resume after reboot will not auto-fire" >&2
  fi

  # Schedule the reboot. Don't sleep here — let the caller exit cleanly first
  # so process-tree state is sane when shutdown runs.
  if command -v shutdown >/dev/null 2>&1; then
    sudo shutdown -r now &
    disown 2>/dev/null || true
  else
    echo "request_reboot: shutdown not available; user must reboot manually" >&2
  fi

  return 0
}

# resume_service_disable - called when the queue completes; turns the systemd
# unit back off so it doesn't fire on every subsequent boot.
resume_service_disable() {
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable "$RESUME_SERVICE_NAME" 2>/dev/null || true
  fi
}
