#!/bin/bash

## Installation file for updating packages with apt-get.
MODULE="Update & Upgrade Packages"
DESCRIPTION="Updates and upgrades the currenlty installed packages."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_PKUPD="config/pkupd.config"
FILE_STATUS_OS_NAME="os.status"
FILE_STATUS_PKUPD_NAME="pkupd.status"
FILE_STATUS_PKUPD_TIME_NAME="pkupd.status.time"
FILE_SOURCES_LIST="/etc/apt/sources.list"
STATUS_UPDATE="Not Run"
STATUS_UPDATE_RUN=""
STATUS_UPGRADE="Not Run"
STATUS_UPGRADE_RUN=""
STATUS_AUTOREMOVE="Not Run"
STATUS_AUTOREMOVE_RUN=""
STATUS="Not Run"
EXIT_CODE=0

# Look for installicious.config file.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the configuration file $FILE_CONFIG_INSTALLICIOUS."

# Source installicious config and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_INSTALLICIOUS."

# Look for pkupd.config file.
if [[ ! -f $FILE_CONFIG_PKUPD ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_PKUPD."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the configuration file $FILE_CONFIG_PKUPD."

# Source pkupd config and check if it was successful.
source $FILE_CONFIG_PKUPD
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_PKUPD. Error Code: $RET_VAL."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_PKUPD."

FILE_STATUS_OS=$PATH_STATUS/$FILE_STATUS_OS_NAME
FILE_STATUS_PKUPD=$PATH_STATUS/$FILE_STATUS_PKUPD_NAME
FILE_STATUS_TIME_PKUPD=$PATH_STATUS/$FILE_STATUS_PKUPD_TIME_NAME

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER=$PATH_LOGS/installicious.log
else
  FILE_LOG_INSTALLER=$PATH_LOGS/$FILE_LOG_INSTALLICIOUS
fi

# No Dependencies

# Load OS Statuses
if [[ -e $FILE_STATUS_OS ]]; then
  source $FILE_STATUS_OS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load required OS Status from file $FILE_STATUS_OS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the required OS Status from file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load required OS Status due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Load PkUpd Status Times
if [[ -f $FILE_STATUS_TIME_PKUPD ]]; then
  source $FILE_STATUS_TIME_PKUPD
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to load Update Times from file $FILE_STATUS_TIME_PKUPD, so all updates will occur." | sudo tee --append $FILE_LOG_INSTALLER
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the Update Times from file $FILE_STATUS_TIME_PKUPD." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Unable to load Update Times due to missing file $FILE_STATUS_TIME_PKUPD so all updates will occur." | sudo tee --append $FILE_LOG_INSTALLER
fi

# Fix sources for old releases so they can be updated.
if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" ]]; then
  if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package lists to legacy in older raspbian release $II_CODENAME already updated to legacy." | sudo tee --append $FILE_LOG_INSTALLER
  else
    sudo sed -i "s/mirrordirector/legacy/g" $FILE_SOURCES_LIST
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_RC_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+2
    else
      if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists to legacy in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_RC_UPGRADE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+2
      fi
    fi
  fi
fi

if [[ $II_CODENAME = "Stretch" ]]; then
  if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package lists to legacy in older raspbian release $II_CODENAME already updated to legacy." | sudo tee --append $FILE_LOG_INSTALLER
  else
    sudo sed -i "s/raspbian.raspberrypi/legacy.raspbian/g" $FILE_SOURCES_LIST
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_RC_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+2
    else
      if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists to legacy in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
      fi
    fi
  fi
fi

# Don't proceede if we already have an error.
if [[ $EXIT_CODE -eq 0 ]]; then
  UPDATE_NOW=$(date '+%Y-%m-%d %T')
  UPDATE_NOW_UNIX=$(date --date="$UPDATE_NOW" +%s)
  
  if [[ -z $ACCEPTABLE_TIME_DELTA_SEC ]]; then
    ACCEPTABLE_TIME_DELTA_SEC=0
  fi  

  # The process is sequential and it either all works or doesn't. Warnings during the process are acceptable and
  # usually due to incorrect repositories. TODO: Add check for out of date repositories and fix.
  if [[ -z $PKUPD_UPDATE_RUN || $(($UPDATE_NOW_UNIX - $(date --date="$PKUPD_UPDATE_RUN" +%s))) -gt $ACCEPTABLE_TIME_DELTA_SEC ]]; then
    SKIPPED_UPDATE=0
    sudo DEBIAN_FRONTEND="noninteractive" apt-get update --yes
  else
    SKIPPED_UPDATE=1
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Apt-get Update is current as it was run less than $ACCEPTABLE_TIME_DELTA_SEC seconds ago. Last run $PKUPD_UPDATE_RUN." | sudo tee --append $FILE_LOG_INSTALLER
  fi
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to successfully complete the apt-get Update. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_UPDATE="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+4
  else
    if [[ $SKIPPED_UPDATE -ne 1 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the apt-get Update." | sudo tee --append $FILE_LOG_INSTALLER
    fi
    STATUS_UPDATE="Completed"
    STATUS_UPDATE_RUN=$(date '+%Y-%m-%d %T')
    if [[ -z $PKUPD_UPGRADE_RUN || $(($UPDATE_NOW_UNIX - $(date --date="$PKUPD_UPGRADE_RUN" +%s))) -gt $ACCEPTABLE_TIME_DELTA_SEC ]]; then
      SKIPPED_UPGRADE=0
      sudo DEBIAN_FRONTEND="noninteractive" apt-get dist-upgrade --yes --show-progress
    else
      SKIPPED_UPGRADE=1
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Apt-get Distribution Upgrade is current as it was run less than $ACCEPTABLE_TIME_DELTA_SEC seconds ago. Last run $PKUPD_UPGRADE_RUN." | sudo tee --append $FILE_LOG_INSTALLER
    fi
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to successfully complete the apt-get Distribution Upgrade. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+8
    else
      if [[ $SKIPPED_UPGRADE -ne 1 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the apt-get Distribution Upgrade." | sudo tee --append $FILE_LOG_INSTALLER
      fi
      STATUS_UPGRADE="Completed"
      STATUS_UPGRADE_RUN=$(date '+%Y-%m-%d %T')
      if [[ -z $PKUPD_AUTOREMOVE_RUN || $(($UPDATE_NOW_UNIX - $(date --date="$PKUPD_AUTOREMOVE_RUN" +%s))) -gt $ACCEPTABLE_TIME_DELTA_SEC ]]; then
        SKIPPED_AUTORUN=0
        sudo DEBIAN_FRONTEND="noninteractive" apt-get autoremove --yes --show-progress
      else
        SKIPPED_AUTORUN=1
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Apt-get Auto-Remove is current as it was run less than $ACCEPTABLE_TIME_DELTA_SEC seconds ago. Last run $PKUPD_AUTOREMOVE_RUN." | sudo tee --append $FILE_LOG_INSTALLER
      fi
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to successfully complete the apt-get Auto-Remove. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_AUTOREMOVE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+16
      else
        if [[ $SKIPPED_AUTORUN -ne 1 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the apt-get Auto-Remove." | sudo tee --append $FILE_LOG_INSTALLER
        fi
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the PKUPD installation." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_AUTOREMOVE="Completed"
        STATUS_AUTOREMOVE_RUN=$(date '+%Y-%m-%d %T')
        STATUS="Completed"
      fi
    fi
  fi
fi

CURRENT_RUN="$(date '+%Y-%m-%d %T.%5N')"

# Remove existing status file.
if [[ -e $FILE_STATUS_PKUPD ]]; then
  sudo rm --force "$FILE_STATUS_PKUPD"
fi

echo "PKUPD_LAST_RUN=\"${CURRENT_RUN}\"" > $FILE_STATUS_PKUPD
echo "PKUPD_UPDATE=\"${STATUS_UPDATE}\"" >> $FILE_STATUS_PKUPD
echo "PKUPD_UPGRADE=\"${STATUS_UPGRADE}\"" >> $FILE_STATUS_PKUPD
echo "PKUPD_AUTOREMOVE=\"${STATUS_AUTOREMOVE}\"" >> $FILE_STATUS_PKUPD
echo "PKUPD_STATUS=\"${STATUS}\"" >> $FILE_STATUS_PKUPD

echo "PKUPD_LAST_RUN=\"${CURRENT_RUN}\"" > $FILE_STATUS_TIME_PKUPD
echo "PKUPD_UPDATE_RUN=\"${STATUS_UPDATE_RUN}\"" >> $FILE_STATUS_TIME_PKUPD
echo "PKUPD_UPGRADE_RUN=\"${STATUS_UPGRADE_RUN}\"" >> $FILE_STATUS_TIME_PKUPD
echo "PKUPD_AUTOREMOVE_RUN=\"${STATUS_AUTOREMOVE_RUN}\"" >> $FILE_STATUS_TIME_PKUPD

if [[ $EXIT_CODE -eq 0 ]]; then
  echo -e "[  \e[92mOK\e[0m  ] Installicious successfully completed the package updates for the Raspberry Pi."
else
  echo -e "[ \e[101mERR!\e[0m ] Installicious could not update the packages for the Raspberry Pi. Error Code: $EXIT_CODE."
fi

exit $EXIT_CODE
