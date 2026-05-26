#!/bin/bash

# scripts/resume.sh - Entry point invoked by installicious-resume.service after
# a reboot. Loads the persisted queue state and continues the queue.
#
# Triggered automatically by systemd when /etc/installicious/state/queue.sh
# exists at boot (per the unit's ConditionPathExists). When the queue empties,
# scheduler_run_queue calls resume_service_disable which turns the unit back
# off until the next reboot is requested.
#
# Output strategy: stream this script's stdout/stderr to /dev/tty1 (when
# writable) AND a transcript file under PATH_STATE. The /etc/profile.d/
# installicious shell wrapper looks for the transcript on the next login —
# if the resume is still running it tail-f's the transcript live, otherwise
# it replays the completed transcript. Lets SSH'd users see the resume even
# though tty1 is the physical console.
#
# stdbuf -oL forces tee to line-buffer so tail -f sees lines as they're
# written, not in 4 KiB chunks.

# Resolve the transcript path. installicious.config sourcing happens below;
# do this here so we can set up the redirect before the rest of the script
# runs. PATH_STATE is the only thing we need from config and it's reliably
# /etc/installicious/state on production installs.
_RESUME_TRANSCRIPT_FILE="/etc/installicious/state/resume-transcript.log"
sudo mkdir -p "$(dirname "$_RESUME_TRANSCRIPT_FILE")" 2>/dev/null \
  || mkdir -p "$(dirname "$_RESUME_TRANSCRIPT_FILE")" 2>/dev/null
# Truncate any prior resume's transcript so a fresh tail-f sees only
# this run's output.
: > "$_RESUME_TRANSCRIPT_FILE" 2>/dev/null \
  || sudo sh -c ": > '$_RESUME_TRANSCRIPT_FILE'" 2>/dev/null

if [[ -w /dev/tty1 ]]; then
  exec > >(stdbuf -oL tee -a /dev/tty1 "$_RESUME_TRANSCRIPT_FILE") 2>&1
else
  exec > >(stdbuf -oL tee -a "$_RESUME_TRANSCRIPT_FILE") 2>&1
fi

# PID sentinel — written before any further work, removed on exit (any
# exit, including signals via the EXIT trap). Lets installicious-shell.sh
# detect end-of-resume by polling `kill -0 $pid`, which is more reliable
# than `systemctl is-active` (which can flake on transient daemon-reloads
# triggered by package postinsts during apt installs) or `kill -0 $tail_pid`
# (which exits early if tail itself dies for any reason — OOM, SIGPIPE,
# tty hiccup). Hardcoded path because PATH_STATE isn't sourced yet here
# and the path is invariant across installs.
_RESUME_PID_FILE="/etc/installicious/state/resume.pid"
echo "$$" > "$_RESUME_PID_FILE" 2>/dev/null
trap 'rm -f "$_RESUME_PID_FILE" 2>/dev/null' EXIT

II_TITLE="Installicious Resume"

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/manifest.sh
source lib/state.sh
source lib/reboot.sh
source lib/scheduler.sh
source lib/post_install.sh

# Pre-warm the manifest registry in THIS shell. Mirrors the fix in
# scripts/options.sh (commit 90e8ca0): post_install_print_queue_summary
# does ~2 subshell-substitution calls per attempted installer to look up
# titles, and each subshell would cold-load the registry from disk
# (writes to the cache die with the subshell). On a Pi with a 20+
# installer queue that's 30+ seconds of summary-printing — long enough
# that installicious-shell.sh's tail-watcher gives up before the summary
# lands. One load here populates _MANIFEST_BLOCK / _MANIFEST_PATH in the
# parent so every subshell starts warm.
_manifest_registry_load

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

# One-line record of which user config-override layers are in play, so a
# resumed run's log shows whether overrides/configuration.override applies.
state_log_override_status

# menu-config.sh is intentionally preserved across runs so the user's edits
# (API keys, hostnames, etc.) survive into future installicious sessions
# without having to be re-entered. Reset manually with
# `sudo rm $PATH_STATE/menu-config.sh` if desired.

echo
echo "============================================================"
echo "  Installicious: resuming queue after reboot"
echo "  Log file: $FILE_LOG_INSTALLER"
echo "============================================================"
echo

scheduler_resume
rc=$?

echo
echo "============================================================"
if [[ $rc -eq 0 ]]; then
  echo "  Installicious: queue completed successfully."
  post_install_apply
elif [[ $rc -eq 255 ]]; then
  echo "  Installicious: another reboot was requested; rebooting again..."
  # Don't apply — queued commands and notes will run after the next resume.
else
  echo "  Installicious: queue exited with errors (rc=$rc)."
  echo "  See log:    $FILE_LOG_INSTALLER"
  echo "  Or journal: sudo journalctl -u installicious-resume"
  post_install_apply
fi
echo "============================================================"
echo

exit $rc
