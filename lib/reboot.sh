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

  # Best-effort enable the resume service. systemctl exists on all our target
  # OSes (Bookworm/Trixie and forward) but be defensive.
  if command -v systemctl >/dev/null 2>&1; then
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
