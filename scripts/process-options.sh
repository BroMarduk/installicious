#!/bin/bash

## The main file to run for Installicious.
MODULE="Process Options"
DESCRIPTION="Processes the selected options previously selected based on the current configuration of hardware and Raspberry Pi OS."
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
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

FILE_STATUS_OPTIONS="$PATH_STATUS/options.status"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

if [[ -s $FILE_STATUS_OPTIONS ]]; then
  read OPTIONS < $FILE_STATUS_OPTIONS
  declare -a "OPTIONS_LIST=( $(echo $OPTIONS | tr '`$<>' '????') )"
  for OPTIONS_ITEM in "${OPTIONS_LIST[@]}";
    do
      PATH_STATUS_OPTIONS_ITEM=$PATH_STATUS/"${OPTIONS_ITEM,,}".status
      if [[ -f $PATH_STATUS_OPTIONS_ITEM ]]; then
        source $PATH_STATUS_OPTIONS_ITEM
        RET_VAL=$?
        if [[ $RET_VAL -eq 0 ]]; then
          # declare -n STATUS_OPTIONS_ITEM=${OPTIONS_ITEM^^}_STATUS
          STATUS_OPTIONS_ITEM_VARNAME="RCONF_GPU_MEM_SPLIT_LITE_${OPTIONS_ITEM^^}_STATUS"
          STATUS_OPTIONS_ITEM=${!STATUS_OPTIONS_ITEM_VARNAME}
        fi
      else
        STATUS_OPTIONS_ITEM=""
      fi
      if [[ $STATUS_OPTIONS_ITEM != "Completed" ]]; then
        OPTIONS_INSTALLER="$PATH_INSTALLERS/install-${OPTIONS_ITEM,,}.sh"
        if [[ -e $OPTIONS_INSTALLER ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Processing the script $OPTIONS_INSTALLER to process option $OPTIONS_ITEM." | sudo tee --append $FILE_LOG_INSTALLER
          bash "$OPTIONS_INSTALLER"
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the script $OPTIONS_INSTALLER to process option $OPTIONS_ITEM." | sudo tee --append $FILE_LOG_INSTALLER
        fi
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipping option $OPTIONS_ITEM due to completed status." | sudo tee --append $FILE_LOG_INSTALLER
      fi
    done
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No items selected to process." | sudo tee --append $FILE_LOG_INSTALLER
fi

bash "$PATH_SCRIPTS/process-software.sh"
