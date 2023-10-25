#!/bin/bash

## The main file to run for Installicious.
MODULE="Options Selection"
DESCRIPTION="Selects the options to be installed. Some options may not be available based on the current configuration of hardware and Raspberry Pi OS."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

## Input Base Variables and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

FILE_STATUS_OS="$PATH_STATUS/os.status"
FILE_STATUS_OPTIONS="$PATH_STATUS/options.status"

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
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load required OS Status from the configuration file $FILE_STATUS_OS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load required OS Status due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Check Dependencies
WHIPTAIL_RESULT=$(sudo bash "$PATH_DEPENDENCIES/whiptail.sh")
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to check for or install package Whiptail. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Remove any existing options configuration files
if [[ -e $FILE_STATUS_OPTIONS ]]; then
  sudo rm --force "$FILE_STATUS_OPTIONS"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to remove existing options status file. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

OPTIONS=(
  PkUpd  "Update Raspberry Pi OS package " on
  RConf  "Standard raspi-config options "  on
  Bash   "Standard Bash customizations "   on
  MOTD   "Add Message of the Day "         on
  Static "Set Static IP Address "          off
  Camera "Enable Legacy Camera support "   off
  VNC    "Enable RealVNC remote access "   off
  SPI    "Enable SPI kernal module "       off
  I2C    "Enable I2C kernal module "       off
  Serial "Enable Serial Port messaging "   off
  1Wire  "Enable 1-Wire interface "        off
  GPIO   "Enable GPIO Pin access "         off
)

OPTIONS_SELECTED=$(whiptail --title "$MODULE" --ok-button "SELECT" --cancel-button "NONE" --checklist "$DESCRIPTION" 20 80 12 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)

if [[ -z $OPTIONS_SELECTED ]]; then
  touch $FILE_STATUS_OPTIONS
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] User $CURRENTUSER continued without selecting any options." | sudo tee --append $FILE_LOG_INSTALLER
else
  echo "$OPTIONS_SELECTED" > $FILE_STATUS_OPTIONS
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] User $CURRENTUSER selected options $OPTIONS_SELECTED." | sudo tee --append $FILE_LOG_INSTALLER
fi

bash "$PATH_SCRIPTS/software.sh"
