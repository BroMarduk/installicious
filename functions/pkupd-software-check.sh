#!/bin/bash

pkupd-software-check() {
  MODULE="$1"
  FILE_LOG="$2"

  FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
  FILE_CONFIG_PKUPD="config/pkupd.config"
  FILE_STATUS_PKUPD_NAME="pkupd.status"
  FILE_STATUS_PKUPD_TIME_NAME="pkupd.status.time"
  FILE_STATUS_PKUPD_TIM_MISSING=false
  STATUS_UPDATE="Not Run"
  STATUS_UPDATE_RUN=""
  STATUS="Not Run"
  EXIT_CODE=0

  # Look for installicious.config file.
  if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG
    return 2
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG

  # Source installicious config and check if it was successful.
  source $FILE_CONFIG_INSTALLICIOUS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG
    return 3
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG

  # Look for pkupd.config file.
  if [[ ! -f $FILE_CONFIG_PKUPD ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_PKUPD." | sudo tee --append $FILE_LOG
    return 4
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the configuration file $FILE_CONFIG_PKUPD." | sudo tee --append $FILE_LOG

  # Source pkupd config and check if it was successful.
  source $FILE_CONFIG_PKUPD
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_PKUPD. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG
    return 5
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_PKUPD." | sudo tee --append $FILE_LOG
  
  FILE_STATUS_TIME_PKUPD=$PATH_STATUS/$FILE_STATUS_PKUPD_TIME_NAME

  # Load PkUpd Status Times
  if [[ -f $FILE_STATUS_TIME_PKUPD ]]; then
    source $FILE_STATUS_TIME_PKUPD
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to load Update Times from file $FILE_STATUS_TIME_PKUPD, so all updates will occur." | sudo tee --append $FILE_LOG
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the Update Times from file $FILE_STATUS_TIME_PKUPD." | sudo tee --append $FILE_LOG
    fi
  else
    FILE_STATUS_PKUPD_TIM_MISSING=true
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Unable to load Update Times due to missing file $FILE_STATUS_TIME_PKUPD so all updates will occur." | sudo tee --append $FILE_LOG
  fi

  UPDATE_NOW=$(date '+%Y-%m-%d %T')
  UPDATE_NOW_UNIX=$(date --date="$UPDATE_NOW" +%s)

  if [[ -z $ACCEPTABLE_TIME_DELTA_SEC ]]; then
    ACCEPTABLE_TIME_DELTA_SEC=0
  fi

  # Determine if we need to run package update, which would be if we don't have an late update time or the update is outside of the acceptable time delta.
  if [[ -z $PKUPD_UPDATE_RUN || $(($UPDATE_NOW_UNIX - $(date --date="$PKUPD_UPDATE_RUN" +%s))) -gt $ACCEPTABLE_TIME_DELTA_SEC ]]; then
    SKIPPED_UPDATE=0
    sudo DEBIAN_FRONTEND="noninteractive" apt-get update --yes
  else
    SKIPPED_UPDATE=1
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Apt-get Update is current as it was run less than $ACCEPTABLE_TIME_DELTA_SEC seconds ago. Last run $PKUPD_UPDATE_RUN." | sudo tee --append $FILE_LOG
  fi
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the apt-get Update. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG
    STATUS_UPDATE="Error"
    STATUS="Error"
    EXIT_CODE=$RET_VAL
  else
    if [[ $SKIPPED_UPDATE -ne 1 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the apt-get Update." | sudo tee --append $FILE_LOG
      STATUS_UPDATE_RUN=$(date '+%Y-%m-%d %T')
    fi
    STATUS_UPDATE="Completed"
  fi

  if [[ $SKIPPED_UPDATE -ne 1 ]]; then
    if [[ $FILE_STATUS_PKUPD_TIM_MISSING=true ]]; then
      echo "PKUPD_UPDATE_RUN=\"${STATUS_UPDATE_RUN}\"" >> $FILE_STATUS_TIME_PKUPD
    else
      sudo sed -i 's/PKUPD_LAST_RUN="[0-9:.-]*"/PKUPD_LAST_RUN="'"$(date "+%Y-%m-%d %H:%M:%S.%5N")"'"/' $FILE_STATUS_TIME_PKUPD
    fi
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to successfully set the time of the last package update . Error Code: $RET_VAL." | sudo tee --append $FILE_LOG
      STATUS_UPDATE="Warning"
      STATUS="Warning"
      EXIT_CODE=$RET_VAL
    fi
  fi

  return $EXIT_CODE
}
