#!/bin/bash

MODULE="WEEWX Installer"
DESCRIPTION="Installs WeeWX weather software via pip."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_FUNCTION_PKUPD_SOFTWARE_CHECK="functions/pkupd-software-check.sh"
FILE_STATUS_WEEWX_NAME="weewx.status"
STATUS_WEEWX="Not Run"
STATUS="Not Run"
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

## Input PKUPD Software Check and check if it was successful.
source $FILE_FUNCTION_PKUPD_SOFTWARE_CHECK
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to functions in file $FILE_FUNCTION_PKUPD_SOFTWARE_CHECK. Error Code: $RET_VAL."
  exit 1
fi

FILE_STATUS_WEEWX="$PATH_STATUS/$FILE_STATUS_WEEWX_NAME"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# Check if we need to run apt-get update
pkupd-software-check $MODULE $FILE_LOG_INSTALLER

RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Error occurred while checking for updates. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_WEEWX="Error"
  STATUS="Error"
  EXIT_CODE=$RET_VAL
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Starting WeeWX installation..." | sudo tee --append $FILE_LOG_INSTALLER
  
  # Check for Python3 and pip
  if ! command -v python3 >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Python3 not found. Installing..." | sudo tee --append $FILE_LOG_INSTALLER
    sudo apt-get install -y python3 >> $FILE_LOG_INSTALLER 2>&1
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Failed to install Python3. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_WEEWX="Error"
      STATUS="Error"
      EXIT_CODE=$RET_VAL
    fi
  fi
  
  if [[ $EXIT_CODE -eq 0 ]] && ! command -v pip3 >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] pip3 not found. Installing..." | sudo tee --append $FILE_LOG_INSTALLER
    sudo apt-get install -y python3-pip >> $FILE_LOG_INSTALLER 2>&1
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Failed to install pip3. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_WEEWX="Error"
      STATUS="Error"
      EXIT_CODE=$RET_VAL
    fi
  fi
  
  # Install required dependencies
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installing required dependencies..." | sudo tee --append $FILE_LOG_INSTALLER
    sudo apt-get install -y python3-configobj python3-cheetah python3-serial >> $FILE_LOG_INSTALLER 2>&1
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Failed to install dependencies. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_WEEWX="Error"
      STATUS="Error"
      EXIT_CODE=$RET_VAL
    fi
  fi
  
  # Install or upgrade weewx using pip
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installing or upgrading weewx via pip3..." | sudo tee --append $FILE_LOG_INSTALLER
    sudo pip3 install --upgrade weewx >> $FILE_LOG_INSTALLER 2>&1
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Failed to install weewx. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_WEEWX="Error"
      STATUS="Error"
      EXIT_CODE=$RET_VAL
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] WeeWX installation completed successfully." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_WEEWX="Completed"
    fi
  fi
fi

# Format the date and time for the status file.
CURRENT_RUN="$(date '+%Y-%m-%d %T.%5N')"

# Update Status
if [[ $STATUS != "Error" ]]; then
  STATUS="Completed"
fi

# Remove existing status file.
if [[ -e $FILE_STATUS_WEEWX ]]; then
  sudo rm --force "$FILE_STATUS_WEEWX"
fi

echo "WEEWX_LAST_RUN=\"${CURRENT_RUN}\"" > $FILE_STATUS_WEEWX
echo "WEEWX_INSTALL=\"${STATUS_WEEWX}\"" >> $FILE_STATUS_WEEWX
echo "WEEWX_STATUS=\"${STATUS}\"" >> $FILE_STATUS_WEEWX

if [[ $II_CODENAME = "Wheezy" ]]; then
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "[ \e[0;32mok\e[0m ] Installicious successfully installed WeeWX."
  else
    echo -e "[\e[0;31mFAIL\e[0m] Installicious could not install WeeWX. Error Code: $EXIT_CODE."
  fi
else
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully installed WeeWX."
  else
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install WeeWX. Error Code: $EXIT_CODE."
  fi
fi

exit $EXIT_CODE
