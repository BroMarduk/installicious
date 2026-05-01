#!/bin/bash

MODULE="Whiptail Dependency Installer"
DESCRIPTION="Installs Whiptail as a dependency which is needed for installicious menus."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_STATUS_DEPENDENCY_NAME="dependency.status"
WHIPTAIL_FOUND=false
STATUS=0
EXIT_CODE=0

# Look for installicious conf file.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

## Input installicious config and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

FILE_STATUS_DEPENDENCY="$PATH_STATUS/$FILE_STATUS_DEPENDENCY_NAME"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# If dependency status file exists, then load it.
if [[ -f $FILE_STATUS_DEPENDENCY ]]; then
  source $FILE_STATUS_DEPENDENCY
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to functions in file $FILE_FUNCTION_PKUPD_SOFTWARE_CHECK. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Check to see if Whiptail is installed and install it if not.
if which whiptail >/dev/null; then
  WHIPTAIL_FOUND=true
fi

if [[ -z $DEPENDENCY_WHIPTAIL ]]; then
else
  sudo apt-get install --yes whiptail
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    STATUS=-1
    EXIT_CODE=$RET_VAL
  fi
  STATUS=1
fi

echo $STATUS
exit $EXIT_CODE
