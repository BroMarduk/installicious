#!/bin/bash

## The main file to run for Installicious.
MODULE="Install Raspi-Config"
DESCRIPTION="Sets the basic settings for raspi-config."
PATH_ZONE_INFO="/usr/share/zoneinfo"
PATH_HOME="/home"
PATH_LINK_TIME_ZONE="/etc/localtime"
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_RCONF="config/rconf.config"
FILE_CONFIG_PKUPD="config/pkupd.config"
FILE_CONFIG_USER="config/user.config"
FILE_STATUS_OS_NAME="os.status"
FILE_STATUS_RCONF_NAME="rconf.status"
FILE_STATUS_PKUPD_NAME="pkupd.status"
FILE_STATUS_PKUPD_TIME_NAME="pkupd.status.time"
FILE_SOURCES_LIST="/etc/apt/sources.list"
FILE_SOURCES_LIST_COLLABORA="/etc/apt/sources.list.d/collabora.list"
FILE_LOCALE_CONFIG="/etc/default/locale"
FILE_KEYBOARD_CONFIG="/etc/default/keyboard"
FILE_KEYBOARD_CONFIG_WHEEZY="/etc/kbd/config"
FILE_KEYBOARD_MAP=".config/lxkeymap.cfg"
FILE_INSTALLER_RCONF_REBOOT="install-rconf-reboot"
FILE_SCRIPT_PROCESS_OPTIONS="process-options"
FILE_LOCALE_GEN="/etc/locale.gen"
FILE_RC_LOCAL="/etc/rc.local"
FILE_CONSOLE_BLANKING="/sys/module/kernel/parameters/consoleblank"
FILE_TIME_ZONE="/etc/timezone"
FILE_LOCAL_TIME="/etc/localtime"
FILE_LIGHTDM_CONFIG="/etc/lightdm/lightdm.conf"
FILE_RASPI_CONFIG="/usr/bin/raspi-config"
FILE_LEGACY_CONFIG="legacy-config.sh"
EXIT_REBOOT=255
SUPPORT_RPI_CONFIG_CMDLINE_FULL=0
SUPPORT_RPI_CONFIG_CMDLINE_BASIC=1
SUPPORT_RPI_CONFIG_CMDLINE_NONE=2
STATUS_UPDATE_RASPI_CONFIG="Not Run"
STATUS_RC_UPGRADE="Not Run"
STATUS_OVERSCAN="Not Run"
STATUS_BLANKING="Not Run"
STATUS_BLANKING_CONSOLE="Not Run"
STATUS_GPU_MEM_SPLIT="Not Run"
STATUS_CHANGE_LOCALE="Not Run"
STATUS_CHANGE_TIME_ZONE="Not Run"
STATUS_CONFIG_KEYBOARD_LANGUAGE="Not Run"
STATUS_CONFIG_KEYBOARD_MODEL="Not Run"
STATUS_CONFIGURE_WIFI_COUNTRY="Not Run"
STATUS_EXPAND_ROOT_FS="Not Run"
STATUS="Not Run"
RPI_MODEL_ZERO=0
RPI_MODEL_1=1
RPI_MODEL_2=2
RPI_MODEL_3=3
RPI_MODEL_4=4
RPI_MODEL_5=5
RPI_CONFIG_CMDLINE_FULL=0 
RPI_CONFIG_CMDLINE_LIGHT=1
RPI_CONFIG_CMDLINE_NONE=2
REBOOT_REQUIRED=0
EXIT_CODE=0

# Look for installicious conf file.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

# Source installicious config and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

# Look for rconf config file.
if [[ ! -f $FILE_CONFIG_RCONF ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_RCONF."
  exit 1
fi

# Source rconf config and check if it was successful.
source $FILE_CONFIG_RCONF
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_RCONF. Error Code: $RET_VAL."
  exit 1
fi

# Look for user config file.
if [[ ! -f $FILE_CONFIG_USER ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_USER."
  exit 1
fi

# Source user config and check if it was successful.
source $FILE_CONFIG_USER
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_USER. Error Code: $RET_VAL."
  exit 1
fi

# Look for pkupd.config file.
if [[ ! -f $FILE_CONFIG_PKUPD ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_PKUPD."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the configuration file $FILE_CONFIG_PKUPD."

# Source pkupd config and check if it was successful.
source $FILE_CONFIG_PKUPD
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_PKUPD. Error Code: $RET_VAL."
  exit 1
fi
echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Loaded the configuration file $FILE_CONFIG_PKUPD."

FILE_STATUS_OS="$PATH_STATUS/$FILE_STATUS_OS_NAME"
FILE_STATUS_RCONF="$PATH_STATUS/$FILE_STATUS_RCONF_NAME"
FILE_STATUS_PKUPD="$PATH_STATUS/$FILE_STATUS_PKUPD_NAME"
FILE_STATUS_TIME_PKUPD="$PATH_STATUS/$FILE_STATUS_PKUPD_TIME_NAME"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# Check Dependencies
RASPI_CONFIG_RESULT=$(sudo bash "$PATH_DEPENDENCIES/raspi-config.sh")
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to check for or install package Raspi-Config. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Load OS Statuses
if [[ -e $FILE_STATUS_OS ]]; then
  source $FILE_STATUS_OS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Status from file $FILE_STATUS_OS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the required OS Status from file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Status due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Load PkUpd Status
if [[ -f $FILE_STATUS_PKUPD ]]; then
  source $FILE_STATUS_PKUPD
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to load Update Status from file $FILE_STATUS_PKUPD, so update will occur." | sudo tee --append $FILE_LOG_INSTALLER
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully loaded the Update Status from file $FILE_STATUS_PKUPD." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Unable to load Update Status due to missing file $FILE_STATUS_PKUPD so updates may occur." | sudo tee --append $FILE_LOG_INSTALLER
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

if [[ $II_CODENAME = "Bookworm" ]]; then
  FILE_BOOT_CMDLINE="/boot/firmware/cmdline.txt"
  FILE_BOOT_CONFIG="/boot/firmware/config.txt"
else
  FILE_BOOT_CMDLINE="/boot/cmdline.txt"
  FILE_BOOT_CONFIG="/boot/config.txt"
fi

UPDATE_NOW=$(date '+%Y-%m-%d %T')
UPDATE_NOW_UNIX=$(date --date="$UPDATE_NOW" +%s)

if [[ -z $ACCEPTABLE_TIME_DELTA_SEC ]]; then
  ACCEPTABLE_TIME_DELTA_SEC=0
fi 

# Determine what Updates if any are needed
if [[ $PKUPD_STATUS = "Completed" ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package update & upgrade completed during this installation so skipping raspi-config Package Update and Upgrades." | sudo tee --append $FILE_LOG_INSTALLER
    NEED_PKG_UPGRADE=0
    NEED_PKG_UPDATE=0
else
  # Determine if Updates are needed
  if [[ $PKUPD_UPDATE = "Completed" ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package update completed during this installation so skipping Package Updates." | sudo tee --append $FILE_LOG_INSTALLER
    NEED_PKG_UPDATE=0
  else
    if [[ ! -z $PKUPD_UPDATE_RUN && $(($UPDATE_NOW_UNIX - $(date --date="$PKUPD_UPDATE_RUN" +%s))) -lt $ACCEPTABLE_TIME_DELTA_SEC ]]; then  
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package Update is current as it was run less than $ACCEPTABLE_TIME_DELTA_SEC seconds ago. Last run $PKUPD_UPDATE_RUN." | sudo tee --append $FILE_LOG_INSTALLER
      NEED_PKG_UPDATE=0
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package Update will need to be run." | sudo tee --append $FILE_LOG_INSTALLER
      NEED_PKG_UPDATE=1
    fi
  fi
  # Determine if Upgrades are needed
  if [[ $NEED_PKG_UPGRADE -eq 1 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package Upgrade will need to be run as it depends on Package Update being current." | sudo tee --append $FILE_LOG_INSTALLER
    NEED_PKG_UPGRADE=1 
  else
    if [[ $PKUPD_UPGRADE = "Completed" ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package Upgrade completed during this installation so skipping upgrades to raspi-config." | sudo tee --append $FILE_LOG_INSTALLER
      NEED_PKG_UPGRADE=0
    else
      if [[ ! -z $PKUPD_UPGRADE_RUN && $(($UPDATE_NOW_UNIX - $(date --date="$PKUPD_UPGRADE_RUN" +%s))) -lt $ACCEPTABLE_TIME_DELTA_SEC ]]; then  
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package Upgrade is current as it was run less than $ACCEPTABLE_TIME_DELTA_SEC seconds ago. Last run $PKUPD_UPGRADE_RUN." | sudo tee --append $FILE_LOG_INSTALLER
        NEED_PKG_UPGRADE=0
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package Upgrade will need to be run." | sudo tee --append $FILE_LOG_INSTALLER
        NEED_PKG_UPGRADE=1
      fi
    fi
  fi
fi

# Do Package Updates in case they were not done.
if [[ $NEED_PKG_UPDATE -ne 0 ]]; then
  if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" ]]; then
    if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package lists to legacy in older raspbian release $II_CODENAME already updated to legacy." | sudo tee --append $FILE_LOG_INSTALLER
    else
      sudo sed -i "s/mirrordirector/legacy/g" $FILE_SOURCES_LIST
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_RC_UPGRADE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+2))
      else
        if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists to legacy in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_RC_UPGRADE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+2))
        fi
      fi
    fi
    if [[ $II_CODENAME = "Wheezy" ]]; then
      if [[ -f $FILE_SOURCES_LIST_COLLABORA ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found obsolete package source [$FILE_SOURCES_LIST_COLLABORA] in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
        sudo rm $FILE_SOURCES_LIST_COLLABORA
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to delete obsolete package source [$FILE_SOURCES_LIST_COLLABORA] in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_RC_UPGRADE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+2))
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully deleted obsolete package source [$FILE_SOURCES_LIST_COLLABORA] in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
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
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_RC_UPGRADE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+2))
      else
        if [[ $(grep "http://legacy.raspbian.org/raspbian/" $FILE_SOURCES_LIST) ]]; then 
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully updated package lists to legacy in older raspbian release $II_CODENAME" | sudo tee --append $FILE_LOG_INSTALLER
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to update package lists to legacy in older raspbian release $II_CODENAME." | sudo tee --append $FILE_LOG_INSTALLER
        fi
      fi
    fi
  fi

  sudo DEBIAN_FRONTEND="noninteractive" apt-get update --yes
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the Package Update. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+2))
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the Package Update." | sudo tee --append $FILE_LOG_INSTALLER
    NEED_PKG_UPDATE=0
    if [[ -z $PKUPD_UPDATE_RUN ]]; then
      STATUS_UPDATE_RUN=$(date '+%Y-%m-%d %T')
      echo "PKUPD_UPDATE_RUN=\"${STATUS_UPDATE_RUN}\"" >> $FILE_STATUS_TIME_PKUPD
    fi
  fi
else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped the Package Update as it was already completed or current." | sudo tee --append $FILE_LOG_INSTALLER 
fi

# Do Upgrade Raspi-Config in caseit was not done.
if [[ $NEED_PKG_UPGRADE -ne 0 ]]; then
  sudo DEBIAN_FRONTEND="noninteractive" apt-get install --only-upgrade raspi-config --yes
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the raspi-config Package Upgrade. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+2))
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the raspi-config Package Upgrade." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Completed"
    STATUS_UPDATE_RUN=$(date '+%Y-%m-%d %T')
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped the raspi-config Package Upgrades as it was already completed or current." | sudo tee --append $FILE_LOG_INSTALLER 
  STATUS_RC_UPGRADE="Completed"
fi

# Check if raspi-config is supported on this OS for some functions - May need to fine tune it based on features.
if [[ ! -z $II_CODENAME ]]; then
  if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" || $II_CODENAME = "Stretch" ]]; then
    if [[ $II_CODENAME = "Wheezy" ]]; then
      SUPPORT_RPI_CONFIG_CMDLINE=$SUPPORT_RPI_CONFIG_CMDLINE_NONE
    else
      SUPPORT_RPI_CONFIG_CMDLINE=$SUPPORT_RPI_CONFIG_CMDLINE_BASIC
    fi
  else
    SUPPORT_RPI_CONFIG_CMDLINE=$SUPPORT_RPI_CONFIG_CMDLINE_FULL
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to determine the OS Codename for Raspi-Config support. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Check if we need to copy new raspi-config files to /usr/bin to support non-pi users.  Only for Jessie and Wheezy.
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -ge $SUPPORT_RPI_CONFIG_CMDLINE_FULL && $II_CODENAME != "Stretch" ]]; then
    if [[ -f "$PATH_RESOURCES/raspi-config-${II_CODENAME,,}" ]]; then
    sudo cp "$PATH_RESOURCES/raspi-config-${II_CODENAME,,}" $FILE_RASPI_CONFIG
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to copy the raspi-config-${II_CODENAME,,} file to /usr/bin. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_UPDATE_RASPI_CONFIG="Error"
      STATUS="Error"
      EXIT_CODE=$((EXIT_CODE+4))
    else
      sudo chmod 755 $FILE_RASPI_CONFIG
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to set the permissions on the raspi-config file in /usr/bin. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_UPDATE_RASPI_CONFIG="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        sed -i "s/SYS_USER=\"[^\"]*\"/SYS_USER=\"$USER_USERNAME\"/" $FILE_RASPI_CONFIG
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to set the default user to [$USER_USERNAME]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_UPDATE_RASPI_CONFIG="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+4))
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully copied the new raspi-config file to /usr/bin, update user, and set permissions." | sudo tee --append $FILE_LOG_INSTALLER
        fi
      fi
    fi
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipping copying the new raspi-config file to /usr/bin as it is not needed." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_UPDATE_RASPI_CONFIG="Skipped"
fi

#TODO add if [[ $II_MODEL_NUM -ge $RPI_MODEL_4 ]]; then for the new overscan setting with 2 HDMIs

# Get the current overscan setting
CURRENT_OVERSCAN=$(sudo grep "^[^#]*disable_overscan=" $FILE_BOOT_CONFIG | awk -F= '{print $2}')
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to get the current overscan setting. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_OVERSCAN="Error"
  STATUS="Error"
  EXIT_CODE=$((EXIT_CODE+4))
else
  if [[ -z $CURRENT_OVERSCAN ]]; then
    CURRENT_OVERSCAN=0
  fi
fi

if [[ $CURRENT_OVERSCAN -ne $RCONF_OVERSCAN ]]; then
  if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
    sudo raspi-config nonint do_overscan $RCONF_OVERSCAN
  else
    if grep -q "^#disable_overscan" $FILE_BOOT_CONFIG; then
      # If disable_overscan is commented out, uncomment it and set the value
      sudo sed -i "s/^#disable_overscan=.*/disable_overscan=$RCONF_OVERSCAN/" $FILE_BOOT_CONFIG
    elif grep -q "^disable_overscan" $FILE_BOOT_CONFIG; then
      # If disable_overscan is not commented, just change its value
      sudo sed -i "s/^disable_overscan=.*/disable_overscan=$RCONF_OVERSCAN/" $FILE_BOOT_CONFIG
    else
      # If disable_overscan doesn't exist, add it
      echo "disable_overscan=$RCONF_OVERSCAN" | sudo tee -a $FILE_BOOT_CONFIG
    fi
  fi
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the overscan change to [$RCONF_OVERSCAN]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_OVERSCAN="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+4))
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the overscan change to [$RCONF_OVERSCAN]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_OVERSCAN="Completed"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The overscan is already set to [$RCONF_OVERSCAN]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_OVERSCAN="Skipped"
fi

# Set the screen blanking setting (GUI)
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_FULL ]]; then
  sudo raspi-config nonint do_blanking $RCONF_BLANKING
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the screen blanking change to [$RCONF_BLANKING]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+4))
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the screen blanking change to [$RCONF_BLANKING]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_BLANKING="Completed"
    REBOOT_REQUIRED=2
  fi
elif [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
  if [[ $II_OS_LEVEL != "Lite" ]]; then
    # Double checked this and in Jessie/Stretch times are in minutes not seconds.
    BLANKING_MINUTES=$(($RCONF_BLANKING_SECONDS / 60))
    # Check if the line is commented out or has a value other than X -s xxx
    if grep -q "^#xserver-command=" $FILE_LIGHTDM_CONFIG; then
      # Uncomment the line and set the value
      sed -i "/^#xserver-command=/s/^#xserver-command=.*/xserver-command=X -s $BLANKING_MINUTES/" $FILE_LIGHTDM_CONFIG
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the screen blanking change to [$BLANKING_MINUTES]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_BLANKING="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the screen blanking change to [$BLANKING_MINUTES]." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_BLANKING="Completed"
        REBOOT_REQUIRED=2
      fi
    elif grep -q "^xserver-command=X -s [0-9]\+" $FILE_LIGHTDM_CONFIG; then
      # Replace the xxx value with TIMEOUT
      if grep -q "^xserver-command=X -s $BLANKING_MINUTES\+" $FILE_LIGHTDM_CONFIG; then
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The screen blanking is already set to [$BLANKING_MINUTES]. Skipping configuration.." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_BLANKING="Skipped"
      else
        sed -i "/^xserver-command=X -s [0-9]\+/s/[0-9]\+/$BLANKING_MINUTES/" $FILE_LIGHTDM_CONFIG
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the screen blanking change to [$BLANKING_MINUTES]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_BLANKING="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+4))
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the screen blanking change to [$BLANKING_MINUTES]." | sudo tee --append $FILE_LOG_INSTALLER 
          STATUS_BLANKING="Completed"
          REBOOT_REQUIRED=2
        fi
      fi
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No need to change GUI screen blanking in Lite version of [$II_CODENAME]." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING="Skipped"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The screen blanking is not supported on Wheezy. Change directly from desktop." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_BLANKING="Skipped"
fi

# Set the console blanking setting
read CONSOLE_BLANKING < $FILE_CONSOLE_BLANKING
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to read the current console blanking setting. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_BLANKING_CONSOLE="Error"
  STATUS="Error"
  EXIT_CODE=$((EXIT_CODE+4))
else
  if [[ $CONSOLE_BLANKING -ne $RCONF_BLANKING_SECONDS ]]; then
    if ! grep -q "consoleblank=" $FILE_BOOT_CMDLINE; then
      sudo sed -i "1 s/$/ consoleblank=$RCONF_BLANKING_SECONDS/" $FILE_BOOT_CMDLINE
    else
      sudo sed -i "s/consoleblank=[0-9]*/consoleblank=$RCONF_BLANKING_SECONDS/" $FILE_BOOT_CMDLINE
    fi
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the console blanking change to [$RCONF_BLANKING_SECONDS]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_BLANKING_CONSOLE="Error"
      STATUS="Error"
      EXIT_CODE=$((EXIT_CODE+4))
    else
      if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_NONE ]]; then   # Wheezy requires an additional setting be changed also
        sudo sed -i "/^#*BLANK_TIME=/c\BLANK_TIME=$RCONF_BLANKING_SECONDS" $FILE_KEYBOARD_CONFIG_WHEEZY
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the Wheezy-pecific console blanking change to [$RCONF_BLANKING_SECONDS]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_BLANKING_CONSOLE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+4))
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the Wheezy-specific console blanking change to [$RCONF_BLANKING_SECONDS]." | sudo tee --append $FILE_LOG_INSTALLER 
          REBOOT_REQUIRED=2
          STATUS_BLANKING_CONSOLE="Completed"
        fi
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the Wheezy-specific console blanking change to [$RCONF_BLANKING_SECONDS]." | sudo tee --append $FILE_LOG_INSTALLER 
        REBOOT_REQUIRED=2
        STATUS_BLANKING_CONSOLE="Completed"
      fi
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The console blanking is already set to [$RCONF_BLANKING_SECONDS]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING_CONSOLE="Skipped"
  fi
fi

# Configure the GPU memory split
if [[ $II_OS_LEVEL = "Lite" ]]; then
  GPU_MEM_SPLIT_VARNAME=RCONF_GPU_MEM_SPLIT_LITE_$II_MEMORY
  GPU_MEM_SPLIT=${!GPU_MEM_SPLIT_VARNAME}
else
  GPU_MEM_SPLIT_VARNAME=RCONF_GPU_MEM_SPLIT_$II_MEMORY
  GPU_MEM_SPLIT=${!GPU_MEM_SPLIT_VARNAME}
fi

GPU_MEM_CURRENT=$(grep "^gpu_mem=" $FILE_BOOT_CONFIG | cut -d '=' -f 2 | cut -d 'M' -f 1)

if [[ $GPU_MEM_SPLIT -ne $GPU_MEM_CURRENT ]]; then
  if [[ -z $GPU_MEM_SPLIT ]]; then
    sudo sed -i '/^gpu_mem=/d' $FILE_BOOT_CONFIG
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully remove the GPU memory split change. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_GPU_MEM_SPLIT="Error"
      STATUS="Error"
      EXIT_CODE=$((EXIT_CODE+4))
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully removed the current GPU memory split." | sudo tee --append $FILE_LOG_INSTALLER
      REBOOT_REQUIRED=2
      STATUS_GPU_MEM_SPLIT="Completed"
    fi
  else
    # Set the GPU memory split if supported by model
    if [[ $SUPPORT_RPI_CONFIG_CMDLINE -eq $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
      if [[ $II_CODENAME = "Bookworm" ]]; then
        # Bookworm stopped supporting do_memory_split in raspi-config.
        sudo $PATH_SCRIPTS/$FILE_LEGACY_CONFIG nonint do_memory_split $GPU_MEM_SPLIT
      else
        sudo raspi-config nonint do_memory_split $GPU_MEM_SPLIT
      fi
    else
      if grep -q "^#gpu_mem" $FILE_BOOT_CONFIG; then
        # If disable_overscan is commented out, uncomment it and set the value
        sudo sed -i "s/^#gpu_mem=.*/gpu_mem=$GPU_MEM_SPLIT/" $FILE_BOOT_CONFIG
      elif grep -q "^gpu_mem" $FILE_BOOT_CONFIG; then
        # If disable_overscan is not commented, just change its value
        sudo sed -i "s/^gpu_mem=.*/gpu_mem=$GPU_MEM_SPLIT/" $FILE_BOOT_CONFIG
      else
        # If disable_overscan doesn't exist, add it
        sudo echo "# uncomment to force a gpu_mem size for the GPU" | sudo tee -a $FILE_BOOT_CONFIG > /dev/null
        sudo echo "gpu_mem=$GPU_MEM_SPLIT" | sudo tee -a $FILE_BOOT_CONFIG > /dev/null
      fi
    fi
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the GPU memory split change to [$GPU_MEM_SPLIT]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_GPU_MEM_SPLIT="Error"
      STATUS="Error"
      EXIT_CODE=$((EXIT_CODE+4))
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the GPU memory split change to [$GPU_MEM_SPLIT]." | sudo tee --append $FILE_LOG_INSTALLER 
      REBOOT_REQUIRED=2
      STATUS_GPU_MEM_SPLIT="Completed"
    fi
  fi
else
  if [[ -z $GPU_MEM_SPLIT ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The GPU Memory split has not currently been set. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_GPU_MEM_SPLIT="Skipped"
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The GPU Memory split is already set to [$GPU_MEM_SPLIT]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_GPU_MEM_SPLIT="Skipped"
  fi
fi

# Configure the time zone. Use raspi-config if supported, otherwise use symbolic link.
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
  TIME_ZONE=$(timedatectl | grep "Time zone" | awk '{print $3}')
  if [[ $TIME_ZONE = $RCONF_TIME_ZONE ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The time zone is already set to [$RCONF_TIME_ZONE.] Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CHANGE_TIME_ZONE="Skipped"
  else
    if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_FULL ]]; then
      sudo raspi-config nonint do_change_timezone "$RCONF_TIME_ZONE"
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully change the time zone to [$RCONF_TIME_ZONE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_TIME_ZONE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully changed the time zone to [$RCONF_TIME_ZONE]." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CHANGE_TIME_ZONE="Completed"
      fi
    else
      sudo ln -sf $PATH_ZONE_INFO/$RCONF_TIME_ZONE $PATH_LINK_TIME_ZONE
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully change the time zone to [$RCONF_TIME_ZONE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_TIME_ZONE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully changed the time zone to [$RCONF_TIME_ZONE]." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CHANGE_TIME_ZONE="Completed"
      fi
    fi
  fi
else
  read TIME_ZONE < $FILE_TIME_ZONE
  if [[ $TIME_ZONE = $RCONF_TIME_ZONE ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The time zone is already set to [$RCONF_TIME_ZONE.] Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CHANGE_TIME_ZONE="Skipped"
  else
    if [[ -f $FILE_LOCAL_TIME ]]; then
      sudo rm $FILE_LOCAL_TIME
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to remove the local time zone file [$FILE_LOCAL_TIME]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_TIME_ZONE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully removed the local time zone file [$FILE_LOCAL_TIME]." | sudo tee --append $FILE_LOG_INSTALLER 
      fi
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The local time zone file [$FILE_LOCAL_TIME] was not found and therefore does not need deleted." | sudo tee --append $FILE_LOG_INSTALLER 
    fi
    echo $RCONF_TIME_ZONE | sudo tee $FILE_TIME_ZONE
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully change the time zone to [$RCONF_TIME_ZONE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CHANGE_TIME_ZONE="Error"
      STATUS="Error"
      EXIT_CODE=$((EXIT_CODE+4))
    else
      sudo dpkg-reconfigure -f noninteractive tzdata
      STATUS_CHANGE_TIME_ZONE="Completed"
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully change the time zone to [$RCONF_TIME_ZONE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_TIME_ZONE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully changed the time zone to [$RCONF_TIME_ZONE]." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CHANGE_TIME_ZONE="Completed"
      fi
    fi
  fi
fi

# Configure the WiFi country.
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
    sudo raspi-config nonint do_wifi_country "$RCONF_WIFI_COUNTRY" > NULL
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the WiFi country configuration to [$RCONF_WIFI_COUNTRY]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CONFIGURE_WIFI_COUNTRY="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+4))
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the WiFi county configuration to [$RCONF_WIFI_COUNTRY]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CONFIGURE_WIFI_COUNTRY="Completed"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The WiFi country setting is not supported for this level. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CONFIGURE_WIFI_COUNTRY="Skipped"
fi

# Configure the Locale and Keyboard settings.
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
  # Get the current locale settings.
  source "$FILE_LOCALE_CONFIG"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load the current locale. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_GPU_MEM_SPLIT="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+8))
  fi

  # Get the current keyboard settings.
  source "$FILE_KEYBOARD_CONFIG"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load the current locale. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_GPU_MEM_SPLIT="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+8))
  fi

  # If both local and keyboard need changed, then we need to reboot in between.
  if [[ $II_OS_LEVEL = "Lite" || $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_BASIC ]]; then
    if [[ $LANG != $RCONF_LOCALE && $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Different locale and keyboard settings requires intermediate reboot." | sudo tee --append $FILE_LOG_INSTALLER 
      REBOOT_REQUIRED=1
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No intermidate reboot required." | sudo tee --append $FILE_LOG_INSTALLER
    fi
  else
    GUI_KB_LAYOUT=$(grep "^layout" $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP| cut -d'=' -f2 | tr -d '"' | tr -d [:blank:])
    if [[ $LANG != $RCONF_LOCALE && ($XKBLAYOUT != $RCONF_KEYBOARD_LANG || $GUI_KB_LAYOUT != $RCONF_KEYBOARD_LANG) ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Different locale and keyboard settings requires intermediate reboot." | sudo tee --append $FILE_LOG_INSTALLER 
      REBOOT_REQUIRED=1
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No intermidate reboot required." | sudo tee --append $FILE_LOG_INSTALLER
    fi
  fi

  # Change the locale if it is not already set correctly.
  if [[ $LANG != $RCONF_LOCALE ]]; then
    if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_FULL ]]; then
      # Use raspi-config to change the locale if supported.
      sudo raspi-config nonint do_change_locale "$RCONF_LOCALE"
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully change the locale to [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_LOCALE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        if [[ $REBOOT_REQUIRED -ne 1 ]]; then
          REBOOT_REQUIRED=2
        fi
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully changed the locale to [$RCONF_LOCALE] - Reboot required." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CHANGE_LOCALE="Completed"
      fi
    else
      # Comment all the locales in the locale.gen file.
      sudo sed -i "s/^[^#]/# &/" $FILE_LOCALE_GEN
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully uncomment the locale [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_LOCALE="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        # Uncomment the locale in the locale.gen file.
        sudo sed -i "s/# $RCONF_LOCALE/$RCONF_LOCALE/" $FILE_LOCALE_GEN
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully uncomment the locale [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_CHANGE_LOCALE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+4))
        else
          # Generate the locale.
          sudo locale-gen
          if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully generate the locale [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_CHANGE_LOCALE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+4))
          else
            # Update the locale.
            sudo localectl set-locale LANG=$RCONF_LOCALE
            RET_VAL=$?
            if [[ $RET_VAL -ne 0 ]]; then
              echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully change the locale to [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
              STATUS_CHANGE_LOCALE="Error"
              STATUS="Error"
              EXIT_CODE=$((EXIT_CODE+4))
            else
              if [[ $REBOOT_REQUIRED -ne 1 ]]; then
                REBOOT_REQUIRED=2
              fi
              STATUS_CHANGE_LOCALE="Completed"
              echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully changed the locale to [$RCONF_LOCALE] - Reboot required." | sudo tee --append $FILE_LOG_INSTALLER 
            fi
          fi
        fi
      fi
    fi
  else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing locale because it was already [$RCONF_LOCALE]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CHANGE_LOCALE="Skipped"
  fi

  # See if we need (one of the settings changed) or can (no pending reboot) change keyboard or model.
  if [[ $REBOOT_REQUIRED -eq 0 && $XKBLAYOUT != $RCONF_KEYBOARD_LANG && ( -z $GUI_KB_LAYOUT || $GUI_KB_LAYOUT != $RCONF_KEYBOARD_LANG ) ]]; then
    
    # Check if the keyboard model is already set to the desired setting.
    if [[ $XKBMODEL != $RCONF_KEYBOARD_MODEL ]]; then
      sudo sed -i "s/XKBMODEL=\".*\"/XKBMODEL=\"$RCONF_KEYBOARD_MODEL\"/" "$FILE_KEYBOARD_CONFIG"
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the keyboard model to [$RCONF_KEYBOARD_MODEL]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_MODEL="Error"
        STATUS="Error"
        EXIT_CODE=$((EXIT_CODE+4))
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the keyboard model to [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CONFIG_KEYBOARD_MODEL="Completed"
      fi
    else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard model because it was already [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CONFIG_KEYBOARD_MODEL="Skipped"
    fi

    # Set the keyboard language
    if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_FULL ]]; then
      if [[ $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
        sudo raspi-config nonint do_configure_keyboard "$RCONF_KEYBOARD_LANG"
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+4))
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
          EXIT_CODE=$((EXIT_CODE+4))
        else
          sudo service keyboard-setup restart
          RET_VAL=$?
          if [[ $RET_VAL -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully restart the keyboard service with language [$RCONF_KEYBOARD_LANG.] Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
            STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
            STATUS="Error"
            EXIT_CODE=$((EXIT_CODE+4))
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
        if [[ $SUPPORT_RPI_CONFIG_CMDLINE -le $SUPPORT_RPI_CONFIG_CMDLINE_NONE ]]; then
          if [[ -z $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP ]]; then
            echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
            STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
            STATUS="Error"
            EXIT_CODE=$((EXIT_CODE+4))
          else
            sudo sed -i "/^layout =/c\layout = $RCONF_KEYBOARD_LANG" $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP
            RET_VAL=$?
            if [[ $RET_VAL -ne 0 ]]; then
              echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
              STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
              STATUS="Error"
              EXIT_CODE=$((EXIT_CODE+4))
            else
              echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Successfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
            fi
          fi
        fi
      fi
    fi
  else
    STATUS_CHANGE_LOCALE="Skipped"
    if [[ $REBOOT_REQUIRED -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because of pending reboot." | sudo tee --append $FILE_LOG_INSTALLER
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard model because it was already [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER
      if [[ ! -z $GUI_KB_LAYOUT ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing gui keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
      fi 
    fi
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The keyboard language and model settings are not supported for this level Use Raspi-Config. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CONFIG_KEYBOARD_LANGUAGE="Skipped"
  STATUS_CONFIG_KEYBOARD_MODEL="Skipped"
fi
# Format the date and time for the status file.
CURRENT_RUN="$(date '+%Y-%m-%d %T.%5N')"

# Update Status
if [[ $STATUS != "Error" && $REBOOT_REQUIRED -ne 1 ]]; then
  STATUS="Completed"
elif [[ $STATUS != "Error" ]]; then
  STATUS="Pending Reboot"
fi

# Remove existing status file.
if [[ -e $FILE_STATUS_RCONF ]]; then
  sudo rm --force "$FILE_STATUS_RCONF"
fi

echo "RCONF_LAST_RUN=\"${CURRENT_RUN}\"" > $FILE_STATUS_RCONF
echo "RCONF_RC_UPGRADE=\"${STATUS_RC_UPGRADE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_UPDATE_RASPI_CONFIG=\"${STATUS_UPDATE_RASPI_CONFIG}\"" >> $FILE_STATUS_RCONF
echo "RCONF_OVERSCAN=\"${STATUS_OVERSCAN}\"" >> $FILE_STATUS_RCONF
echo "RCONF_BLANKING=\"${STATUS_BLANKING}\"" >> $FILE_STATUS_RCONF
echo "RCONF_BLANKING_CONSOLE=\"${STATUS_BLANKING_CONSOLE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_GPU_MEM_SPLIT=\"${STATUS_GPU_MEM_SPLIT}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CHANGE_LOCALE=\"${STATUS_CHANGE_LOCALE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CHANGE_TIME_ZONE=\"${STATUS_CHANGE_TIME_ZONE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CONFIGURE_KEYBOARD=\"${STATUS_CONFIG_KEYBOARD_LANGUAGE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CONFIGURE_KEYBOARD_MODEL=\"${STATUS_CONFIG_KEYBOARD_MODEL}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CONFIGURE_WIFI_COUNTRY=\"${STATUS_CONFIGURE_WIFI_COUNTRY}\"" >> $FILE_STATUS_RCONF
echo "RCONF_EXPAND_ROOT_FS=\"${STATUS_EXPAND_ROOT_FS}\"" >> $FILE_STATUS_RCONF
echo "RCONF_STATUS=\"${STATUS}\"" >> $FILE_STATUS_RCONF

if [[ $EXIT_CODE -eq 0 ]]; then
  if [[ $REBOOT_REQUIRED -ne 0 ]]; then
    if [[ $REBOOT_REQUIRED -eq 1 ]]; then
      if ! (grep -q "Installicious Reboot" $FILE_RC_LOCAL); then
        # Add the command before the 'exit 0' line
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Added reboot to next startup." | sudo tee --append $FILE_LOG_INSTALLER 
        sudo sed -i "/^exit 0$/i # Installicious Reboot to $FILE_INSTALLER_RCONF_REBOOT\ncd $PATH_INSTALLICIOUS;sudo bash $PATH_INSTALLICIOUS/$FILE_INSTALLICIOUS --reboot installer $FILE_INSTALLER_RCONF_REBOOT" "$FILE_RC_LOCAL"
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the reboot to run $FILE_INSTALLER_RCONF_REBOOT. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+16))
          exit $EXIT_CODE
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the reboot to run $FILE_INSTALLER_RCONF_REBOOT." | sudo tee --append $FILE_LOG_INSTALLER 
          STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
          EXIT_CODE=$EXIT_REBOOT
        fi
      fi
    elif [[ $REBOOT_REQUIRED -eq 2 ]]; then
      if ! (grep -q "Installicious Reboot" $FILE_RC_LOCAL); then
        # Add the command before the 'exit 0' line
        sudo sed -i "/^exit 0$/i # Installicious Reboot to $FILE_SCRIPT_PROCESS_OPTIONS\ncd $PATH_INSTALLICIOUS;sudo bash $PATH_INSTALLICIOUS/$FILE_INSTALLICIOUS --reboot script $FILE_SCRIPT_PROCESS_OPTIONS" "$FILE_RC_LOCAL"
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully configure the reboot to run $FILE_SCRIPT_PROCESS_OPTIONS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
          STATUS="Error"
          EXIT_CODE=$((EXIT_CODE+16))
          exit $EXIT_CODE
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the reboot to run $FILE_SCRIPT_PROCESS_OPTIONS." | sudo tee --append $FILE_LOG_INSTALLER 
          STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
          EXIT_CODE=$EXIT_REBOOT
        fi
      fi
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Rebooting with out any additional scripts to be run after reboot." | sudo tee --append $FILE_LOG_INSTALLER 
    fi
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Rebooting Raspberry Pi. Additional logs can be found at $FILE_LOG_INSTALLER." | sudo tee --append $FILE_LOG_INSTALLER
    sudo shutdown -r now
    exit $EXIT_CODE
  fi

  # If no error and no reboot, the we are good to go.
  if [[ $II_CODENAME = "Wheezy" ]]; then
    echo -e "[ \e[0;32mok\e[0m ] Installicious successfully completed the configuration of the Raspberry Pi."
  else
    echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully completed the configuration of the Raspberry Pi."
  fi
else
  if [[ $II_CODENAME = "Wheezy" ]]; then
    echo -e "[\e[0;31mFAIL\e[0m] Installicious could not complete the configuration of the Raspberry Pi. Error Code: $EXIT_CODE."
  else
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not complete the configuration of the Raspberry Pi. Error Code: $EXIT_CODE."
  fi
fi

exit $EXIT_CODE