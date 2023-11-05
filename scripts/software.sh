#!/bin/bash

## The main file to run for Installicious.
MODULE="Options Selection"
DESCRIPTION="Selects the options to be installed. Some options may not be available based on the current configuration of hardware and Raspberry Pi OS."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

## Input Base Variables and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

FILE_STATUS_OS="$PATH_STATUS/os.status"
FILE_STATUS_SOFTWARE="$PATH_STATUS/software.status"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

## Current User
CURRENTUSER="$(whoami)"

## Load Required Variables
if [[ -e $FILE_STATUS_OS ]]; then
  source $FILE_STATUS_OS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Status from the configuration file $FILE_STATUS_OS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Status due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Check Dependencies
WHIPTAIL_RESULT=$(sudo bash "$PATH_DEPENDENCIES/whiptail.sh")
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to check for or install package Whiptail. Error Code: $RET_VAL. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Remove any existing options configuration files
if [[ -e $FILE_STATUS_SOFTWARE ]]; then
  sudo rm --force "$FILE_STATUS_SOFTWARE"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to remove existing software status file. Error Code: $RET_VAL. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

SOFTWARE=(
  ZRam    "Use ZRam Temp logs "                off
  Git     "Install Git "                       off
  Nginx   "Install Nginx web server "          off
  Hyper   "Use Pimoroni HyperPixel display "   off
  PiTFT   "Use PiTFT display "                 off
  7Inch   "Use Raspberry Pi 7in. Touchscreen " off
  WeeWx   "Install WeeWx Software "            off
  PyCharm "Install PyCharm Debugging "         off
  Pip     "Install Pip for Python "            off
)

SOFTWARE_SELECTED=$(whiptail --title "$INSTALLER" --ok-button "SELECT" --cancel-button "NONE" --checklist "$DESCRIPTION." 19 80 11 "${SOFTWARE[@]}" 3>&1 1>&2 2>&3)

if [[ -z $SOFTWARE_SELECTED ]]; then
  touch $FILE_STATUS_SOFTWARE
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] User $CURRENTUSER continued without selecting any software." | sudo tee --append $FILE_LOG_INSTALLER
else
  echo "$SOFTWARE_SELECTED" > $FILE_STATUS_SOFTWARE
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] User $CURRENTUSER selected software $SOFTWARE_SELECTED." | sudo tee --append $FILE_LOG_INSTALLER
fi

bash "$PATH_SCRIPTS/process-options.sh"
