#!/bin/bash

# scripts/resume.sh - Entry point invoked by installicious-resume.service after
# a reboot. Loads the persisted queue state and continues the queue.
#
# Triggered automatically by systemd when /etc/installicious/state/queue.sh
# exists at boot (per the unit's ConditionPathExists). When the queue empties,
# scheduler_run_queue calls resume_service_disable which turns the unit back
# off until the next reboot is requested.

II_TITLE="Installicious Resume"

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/manifest.sh
source lib/state.sh
source lib/reboot.sh
source lib/scheduler.sh

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

scheduler_resume
exit $?
