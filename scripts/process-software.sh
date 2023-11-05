#!/bin/bash

## The main file to run for Installicious.
MODULE="Process Software"
DESCRIPTION="Processes the software previously selected based on the current configuration of hardware and Raspberry Pi OS."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
EXIT_REBOOT=255

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

## Input Base Variables and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

FILE_STATUS_SOFTWARE="$PATH_STATUS/software.status"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

if [[ -s $FILE_STATUS_SOFTWARE ]]; then
  read SOFTWARE < $FILE_STATUS_SOFTWARE
  declare -a "SOFTWARE_LIST=( $(echo $SOFTWARE | tr '`$<>' '????') )"
  for SOFTWARE_ITEM in "${SOFTWARE_LIST[@]}";
    do
      PATH_STATUS_SOFTWARE_ITEM=$PATH_STATUS/"${SOFTWARE_ITEM,,}".status
      if [[ -f $PATH_STATUS_SOFTWARE_ITEM ]]; then
        source $PATH_STATUS_SOFTWARE_ITEM
        RET_VAL=$?
        if [[ $RET_VAL -eq 0 ]]; then
          # declare -n STATUS_SOFTWARE_ITEM=${SOFTWARE_ITEM^^}_STATUS
          STATUS_SOFTWARE_ITEM_VARNAME="${SOFTWARE_ITEM^^}_STATUS"
          STATUS_SOFTWARE_ITEM=${!STATUS_SOFTWARE_ITEM_VARNAME}
        fi
      else
        STATUS_SOFTWARE_ITEM=""
      fi
      if [[ $STATUS_SOFTWARE_ITEM != "Completed" ]]; then
        SOFTWARE_INSTALLER="$PATH_INSTALLERS/install-${SOFTWARE_ITEM,,}"
        if [[ -e $SOFTWARE_INSTALLER ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Processing the script $SOFTWARE_INSTALLER to process software $SOFTWARE_ITEM." | sudo tee --append $FILE_LOG_INSTALLER
          bash "$SOFTWARE_INSTALLER"
          RET_VAL=$?
          if [[ $RET_VAL -eq $EXIT_REBOOT ]]; then
            echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Stopping due to reboot result from script $SOFTWARE_INSTALLER." | sudo tee --append $FILE_LOG_INSTALLER
            exit 0
          fi
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the script $SOFTWARE_INSTALLER to process option $SOFTWARE_ITEM." | sudo tee --append $FILE_LOG_INSTALLER
        fi
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipping software $SOFTWARE_ITEM due to completed status." | sudo tee --append $FILE_LOG_INSTALLER
      fi
    done
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No software selected to process." | sudo tee --append $FILE_LOG_INSTALLER
fi
