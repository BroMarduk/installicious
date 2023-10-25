#!/bin/bash

## Installation file for updating packages with apt-get.
MODULE="Update & Upgrade Packages"
DESCRIPTION="Updates and upgrades the currenlty installed packages."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
STATUS_UPDATE="Not Run"
STATUS_UPGRADE="Not Run"
STATUS_AUTOREMOVE="Not Run"
STATUS="Not Run"
EXIT_CODE=0

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the configuration file $FILE_CONFIG_INSTALLICIOUS."

## Input installicious config and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_INSTALLICIOUS."

FILE_STATUS_OS="$PATH_STATUS/os.status"
FILE_STATUS_PKUPD="$PATH_STATUS/pkupd.status"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# No Dependencies

## Load Required Variables
if [[ -e $FILE_STATUS_OS ]]; then
  source $FILE_STATUS_OS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load required OS Configuration due to error loading variables. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load required OS Configuration due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully loaded the required OS Configuration from file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER

# Fix sources for old releases so they can be updated.
if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" ]]; then
  sudo sed -i "s/mirrordirector/legacy/g" /etc/apt/sources.list
  if [[ $RET_VAL -ne 0 ]]; then
    if [[ -z $(grep "legacy" /etc/apt/sources.list) ]]; then 
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to update package lists in older raspbian release $II_CODENAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_RC_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+2
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists to legacy in older raspbian release $II_CODENAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    fi
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
elif [[ $II_CODENAME = "Stretch" ]]; then
  sudo sed -i "s/raspbian.raspberrypi/legacy.raspbian/g" /etc/apt/sources.list
  if [[ $RET_VAL -ne 0 ]]; then
    if [[ -z $(grep "legacy" /etc/apt/sources.list) ]]; then 
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to updated package lists to legacy in older raspbian release $II_CODENAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_RC_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+2
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists in older raspbian release $II_CODENAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    fi
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No need to update package lists to legacy in raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
fi

# The process is sequential and it either all works or doesn't. Warnings during the process are acceptable and
# usually due to incorrect repositories. TODO: Add check for out of date repositories and fix.
export DEBIAN_FRONTEND="noninteractive"
sudo apt-get update --yes
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the apt-get Update. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_UPDATE="Error"
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+4
else
  STATUS_UPDATE="Completed"
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the apt-get Update." | sudo tee --append $FILE_LOG_INSTALLER
  sudo apt-get dist-upgrade --yes --show-progress;
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the apt-get Distribution Upgrade. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_UPGRADE="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+8
  else
    STATUS_UPGRADE="Completed"
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the apt-get Distribution Upgrade." | sudo tee --append $FILE_LOG_INSTALLER
    sudo apt-get autoremove --yes --show-progress
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the apt-get Auto Remove. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_AUTOREMOVE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+16
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the apt-get Auto-Remove." | sudo tee --append $FILE_LOG_INSTALLER
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the PKUPD installation." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_AUTOREMOVE="Completed"
      STATUS="Completed"
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

exit $EXIT_CODE
