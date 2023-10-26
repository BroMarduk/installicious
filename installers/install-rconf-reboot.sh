#!/bin/bash

## The main file to run for Installicious.
MODULE="Install Raspi-Config Reboot"
DESCRIPTION="Sets the basic settings for raspi-config after reboot."
PATH_HOME="/home"
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_RCONF="config/rconf.config"
FILE_CONFIG_USER="config/user.config"
FILE_KEYBOARD_CONFIG="/etc/default/keyboard"
FILE_KEYBOARD_MAP=".config/lxkeymap.cfg"
FILE_SCRIPT_PROCESS_OPTIONS="process-options.sh"
STATUS_CONFIG_KEYBOARD="Not Run"
STATUS="Not Run"
EXIT_CODE=0

# Look for installicious conf file.
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

# Look for rconf config file.
if [[ ! -f $FILE_CONFIG_RCONF ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_RCONF."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_RCONF."

## Input rconf config and check if it was successful.
source $FILE_CONFIG_RCONF
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load the configuration file $FILE_CONFIG_RCONF. Error Code: $RET_VAL."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully sourced the configuration file $FILE_CONFIG_RCONF."

# Look for user config file.
if [[ ! -f $FILE_CONFIG_USER ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_USER."
  exit 1
fi

# Input user config and check if it was successful.
source $FILE_CONFIG_USER
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_USER. Error Code: $RET_VAL."
  exit 1
fi

FILE_STATUS_OS="$PATH_STATUS/os.status"
FILE_STATUS_PKUPD="$PATH_STATUS/pkupd.status"
FILE_STATUS_RCONF="$PATH_STATUS/rconf.status"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

## Check Dependencies
RASPI_CONFIG_RESULT=$(sudo bash "$PATH_DEPENDENCIES/raspi-config.sh")
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to check for or install package Raspi-Config. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 2
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully checked for and potentially installed package Raspi-Config." | sudo tee --append $FILE_LOG_INSTALLER

## Load Required Variables
if [[ -e $FILE_STATUS_OS ]]; then
  source $FILE_STATUS_OS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Configuration due to error loading variables. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 4
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the required OS Configuration from file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Configuration due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 4
fi

if [[ -z $II_CODENAME ]]; then
  if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" || $II_CODENAME = "Stretch" ]]; then
    SUPPORT_RPI_CONFIG_CMDLINE=0
  else
    SUPPORT_RPI_CONFIG_CMDLINE=1
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to determine the OS Codename and Raspi-Config support. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Get the current keyboard setting.
source "$FILE_KEYBOARD_CONFIG"
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load the current keyboard settings. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 4
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the current keyboard settings." | sudo tee --append $FILE_LOG_INSTALLER

# Check if the keyboard model is already set to the desired setting.
if [[ $XKBMODEL != $RCONF_KEYBOARD_MODEL ]]; then
  sudo sed -i "s/XKBMODEL=\".*\"/XKBMODEL=\"$RCONF_KEYBOARD_MODEL\"/" "$FILE_KEYBOARD_CONFIG"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the keyboard model to [$RCONF_KEYBOARD_MODEL]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CONFIG_KEYBOARD_MODEL="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+4
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the keyboard model to [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CONFIG_KEYBOARD_MODEL="Completed"
  fi
else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard model because it was already [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CONFIG_KEYBOARD_MODEL="Skipped"
fi
    
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -ne 0 ]]; then
  echo "2a" | sudo tee --append $FILE_LOG_INSTALLER 
  if [[ $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
    sudo raspi-config nonint do_configure_keyboard "$RCONF_KEYBOARD_LANG"
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the keyboard language to [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CONFIG_KEYBOARD_LANGUAGE="Skipped"
  fi
else
  if [[ $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
    sudo sed -i "s/XKBLAYOUT=\".*\"/XKBLAYOUT=\"$RCONF_KEYBOARD_LANG\"/" "$FILE_KEYBOARD_CONFIG"
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      sudo service keyboard-setup restart
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully restart the keyboard service with language [$RCONF_KEYBOARD_LANG.] Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
      fi
    fi  
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CONFIG_KEYBOARD_MODEL="Skipped"
  fi
  
  if [[ $II_OS_LEVEL = "Lite" ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the keyboard language to [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
  else
    if [[ ! -f $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      sudo sed -i "/^layout =/c\layout = $RCONF_KEYBOARD_LANG" $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER
      fi
    fi
  fi
fi

# Format the date and time for the status file.
CURRENT_RUN="$(date '+%Y-%m-%d %T.%5N')"

# Update Status
if [[ $STATUS != "Error" ]]; then
  STATUS="Completed"
fi

sudo sed -i "/^RCONF_CONFIGURE_KEYBOARD_MODEL=/c\RCONF_CONFIGURE_KEYBOARD_MODEL=\"$STATUS_CONFIG_KEYBOARD_MODEL\"" $FILE_STATUS_RCONF
sudo sed -i "/^RCONF_CONFIGURE_KEYBOARD=/c\RCONF_CONFIGURE_KEYBOARD=\"$STATUS_CONFIG_KEYBOARD\"" $FILE_STATUS_RCONF
sudo sed -i "s/STATUS=\"Pending Reboot\"/STATUS=\"$STATUS\"/" $FILE_STATUS_RCONF

RET_VAL=$? 
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully set the status of the RCONF_CONFIGURE_KEYBOARD status in $FILE_STATUS_RCONF to $STATUS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  EXIT_CODE=$EXIT_CODE+16
fi

# Update Status
if [[ $STATUS != Error ]]; then
  # After reboot, process options needs to be run again.
  bash "$PATH_SCRIPTS/$FILE_SCRIPT_PROCESS_OPTIONS"
fi

exit $EXIT_CODE
