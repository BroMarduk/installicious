#!/bin/bash

## The main file to run for Installicious.
MODULE="Install Raspi-Config"
DESCRIPTION="Sets the basic settings for raspi-config."
PATH_ZONE_INFO="/usr/share/zoneinfo"
PATH_HOME="/home"
PATH_LINK_TIME_ZONE="/etc/localtime"
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_RCONF="config/rconf.config"
FILE_CONFIG_USER="config/user.config"
FILE_LOCALE_CONFIG="/etc/default/locale"
FILE_KEYBOARD_CONFIG="/etc/default/keyboard"
FILE_KEYBOARD_MAP=".config/lxkeymap.cfg"
FILE_INSTALLER_RCONF_REBOOT="install-rconf-reboot"
FILE_SCRIPT_PROCESS_OPTIONS="process-options"
FILE_LOCALE_GEN="/etc/locale.gen"
FILE_RC_LOCAL="/etc/rc.local"
FILE_BOOT_CMDLINE="/boot/cmdline.txt"
FILE_CONSOLE_BLANKING="/sys/module/kernel/parameters/consoleblank"
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
REBOOT_REQUIRED=0
EXIT_CODE=0

# Look for installicious conf file.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

# Input installicious config and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

# Look for rconf config file.
if [[ ! -f $FILE_CONFIG_RCONF ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_RCONF."
  exit 1
fi

# Input rconf config and check if it was successful.
source $FILE_CONFIG_RCONF
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_RCONF. Error Code: $RET_VAL."
  exit 1
fi

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

# Check Dependencies
RASPI_CONFIG_RESULT=$(sudo bash "$PATH_DEPENDENCIES/raspi-config.sh")
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to check for or install package Raspi-Config. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Load Required Variables
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

# Check if raspi-config is supported on this OS for some functions - May need to fine tune it based on features.
if [[ -z $II_CODENAME ]]; then
  if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" || $II_CODENAME = "Stretch" ]]; then
    SUPPORT_RPI_CONFIG_CMDLINE=0
  else
    SUPPORT_RPI_CONFIG_CMDLINE=1
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to determine the OS Codename and Raspi-Config support. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Load Status from PkUpd
if [[ -e $FILE_STATUS_PKUPD ]]; then
  source $FILE_STATUS_PKUPD
  if [[ $PKUPD_UPGRADE = "Completed" ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package upgrade completed so skipping updates and upgrades to raspi-config." | sudo tee --append $FILE_LOG_INSTALLER
    NEED_DIST_UPGRADE=0
    NEED_PKG_UPDATE=0
  else
    NEED_DIST_UPGRADE=1
    if [[ "$PKUPD_UPDATE" = "Completed" ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package upgrade not completed but updates were so skipping updates but performing upgrades to raspi-config." | sudo tee --append $FILE_LOG_INSTALLER
      NEED_PKG_UPDATE=0
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Package upgrade and updates not completed so will continue with updates and upgrade to raspi-config." | sudo tee --append $FILE_LOG_INSTALLER
      NEED_PKG_UPDATE=1
    fi
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Unable to find package upgrade status so will continue with updates and upgrade to raspi-config." | sudo tee --append $FILE_LOG_INSTALLER
  NEED_DIST_UPGRADE=1
  NEED_PKG_UPDATE=1
fi

# Do Package Updates in case they were not done.
if [[ $NEED_PKG_UPDATE -ne 0 ]]; then
  # Fix sources for old releases so they can be updated.
  if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" ]]; then
    sudo sed -i "s/mirrordirector/legacy/g" /etc/apt/sources.list
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to updated package lists in older raspbian release $II_CODENAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_RC_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+2
    fi
  elif [[ $II_CODENAME = "Stretch" ]]; then
    sudo sed -i "s/raspbian.raspberrypi/legacy.raspbian/g" /etc/apt/sources.list
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to updated package lists in older raspbian release $II_CODENAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_RC_UPGRADE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+2
    fi
  fi
  sudo apt-get update --yes
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the apt-get update. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+2
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the apt-get update." | sudo tee --append $FILE_LOG_INSTALLER
    NEED_PKG_UPDATE=0
  fi
else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped the apt-get updates as they were already completed." | sudo tee --append $FILE_LOG_INSTALLER 
fi

# Do Package Upgrades in case they were not done.
if [[ $NEED_DIST_UPGRADE -ne 0 ]]; then
  sudo apt-get dist-upgrade raspi-config --yes --show-progress
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the raspi-config upgrade. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+2
  else
    if [[ $NEED_PKG_UPDATE -eq 1 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Upgrade to raspi-config completed but could be out of date since apt-get update was not completed. " | sudo tee --append $FILE_LOG_INSTALLER    
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the apt-get uprade for raspi-config." | sudo tee --append $FILE_LOG_INSTALLER 
    fi
    STATUS_RC_UPGRADE="Completed"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped the upgrades to raspi-config as they were already completed." | sudo tee --append $FILE_LOG_INSTALLER 
  STATUS_RC_UPGRADE="Completed"
fi

# Get the current overscan setting
CURRENT_OVERSCAN=$(sudo grep "^[^#]*disable_overscan=" /boot/config.txt | awk -F= '{print $2}')
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the overscan change to [$RCONF_OVERSCAN]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_OVERSCAN="Error"c
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+4
else
  if [[ -z $CURRENT_OVERSCAN ]]; then
    CURRENT_OVERSCAN=0
  fi
fi

if [[ $CURRENT_OVERSCAN -ne $RCONF_OVERSCAN ]]; then
  sudo raspi-config nonint do_overscan $RCONF_OVERSCAN
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the overscan change to [$RCONF_OVERSCAN]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_OVERSCAN="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+4
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the overscan change to [$RCONF_OVERSCAN]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_OVERSCAN="Completed"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The overscan is already set to [$RCONF_OVERSCAN]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_OVERSCAN="Skipped"
fi

# Set the screen blanking setting (GUI)
if [[ $SUPPORT_RPI_CONFIG_CMDLINE -ne 0 ]]; then
  sudo raspi-config nonint do_blanking $RCONF_BLANKING
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the screen blanking change to [$RCONF_BLANKING]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+4
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the screen blanking change to [$RCONF_BLANKING]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_BLANKING="Completed"
    REBOOT_REQUIRED=2
  fi
else
  # TODO: Change this with xset
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The screen blanking is not supported on older Pis. Change directly from desktop." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_BLANKING_CONSOLE="Skipped"
fi

# Set the console blanking setting
read CONSOLE_BLANKING < $FILE_CONSOLE_BLANKING
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to read the current console blanking setting. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_BLANKING_CONSOLE="Error"
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+4
else
  if [[ $CONSOLE_BLANKING -ne $RCONF_BLANKING_CONSOLE ]]; then
    if ! grep -q "consoleblank=" $FILE_BOOT_CMDLINE; then
      sudo sed -i "1 s/$/ consoleblank=$RCONF_BLANKING_CONSOLE/" $FILE_BOOT_CMDLINE
    else
      sudo sed -i "s/consoleblank=[0-9]*/consoleblank=$RCONF_BLANKING_CONSOLE/" $FILE_BOOT_CMDLINE
    fi
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the console blanking change to [$RCONF_BLANKING_CONSOLE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_BLANKING_CONSOLE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the console blanking change to [$RCONF_BLANKING_CONSOLE]." | sudo tee --append $FILE_LOG_INSTALLER 
      REBOOT_REQUIRED=2
      STATUS_BLANKING_CONSOLE="Completed"
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The console blanking is already set to [$RCONF_BLANKING_CONSOLE]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING_CONSOLE="Skipped"
  fi
fi

if [[ $II_OS_LEVEL = "Lite" ]]; then
  declare -n GPU_MEM_SPLIT="RCONF_GPU_MEM_SPLIT_LITE_$II_MEMORY"
else
  declare -n GPU_MEM_SPLIT="RCONF_GPU_MEM_SPLIT_$II_MEMORY"
fi

if [[ -z $GPU_MEM_SPLIT ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the GPU memory split change because setting could not be determined." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_GPU_MEM_SPLIT="Error"
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+4
else
  # Set the GPU memory split if supported by model
  sudo raspi-config nonint do_memory_split $GPU_MEM_SPLIT
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the GPU memory split change to [$GPU_MEM_SPLIT]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_GPU_MEM_SPLIT="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+4
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the GPU memory split change to [$GPU_MEM_SPLIT]." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_GPU_MEM_SPLIT="Completed"
  fi
fi

# Configure the time zone. Use raspi-config if supported, otherwise use symbolic link.
TIME_ZONE=$(timedatectl | grep "Time zone" | awk '{print $3}')
if [[ $TIME_ZONE = $RCONF_TIME_ZONE ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The time zone is already set to [$RCONF_TIME_ZONE.] Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CHANGE_TIME_ZONE="Skipped"
else
  if [[ $SUPPORT_RPI_CONFIG_CMDLINE -ne 0 ]]; then
    sudo raspi-config nonint do_change_timezone "$RCONF_TIME_ZONE"
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully change the time zone to [$RCONF_TIME_ZONE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CHANGE_TIME_ZONE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully changed the time zone to [$RCONF_TIME_ZONE]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CHANGE_TIME_ZONE="Completed"
    fi
  else
    sudo ln -sf $PATH_ZONE_INFO/$RCONF_TIME_ZONE $PATH_LINK_TIME_ZONE
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully change the time zone to [$RCONF_TIME_ZONE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CHANGE_TIME_ZONE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully changed the time zone to [$RCONF_TIME_ZONE]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CHANGE_TIME_ZONE="Completed"
    fi
  fi
fi

# Configure the WiFi country.
sudo raspi-config nonint do_wifi_country "$RCONF_WIFI_COUNTRY"
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully complete the WiFi country configuration to [$RCONF_WIFI_COUNTRY]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CONFIGURE_WIFI_COUNTRY="Error"
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+4
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the WiFi county configuration to [$RCONF_WIFI_COUNTRY]." | sudo tee --append $FILE_LOG_INSTALLER 
  STATUS_CONFIGURE_WIFI_COUNTRY="Completed"
fi

# Files system is expanded automatically on boot for Raspbian Jessie and later, only need this for Wheezy.
if [[ $II_CODENAME = "Wheezy" ]]; then
  sudo raspi-config nonint do_expand_rootfs
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully expand the root file system. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_EXPAND_ROOT_FS="Error"
    STATUS="Error"
    EXIT_CODE=$EXIT_CODE+4
  else
    STATUS_EXPAND_ROOT_FS="Completed"
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully completed the expansion of the root file system." | sudo tee --append $FILE_LOG_INSTALLER 
  fi
else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped expansion of the root file system since the latest releases of $II_CODENAME already do this." | sudo tee --append $FILE_LOG_INSTALLER 
    STATUS_CHANGE_LOCALE="Skipped"
fi

# Get the current locale settings.
source "$FILE_LOCALE_CONFIG"
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load the current locale. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_GPU_MEM_SPLIT="Error"
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+8
fi

# Get the current keyboard settings.
source "$FILE_KEYBOARD_CONFIG"
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to load the current locale. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_GPU_MEM_SPLIT="Error"
  STATUS="Error"
  EXIT_CODE=$EXIT_CODE+8
fi

# If both local and keyboard need changed, then we need to reboot in between.
if [[ $II_OS_LEVEL = "Lite" || $SUPPORT_RPI_CONFIG_CMDLINE -ne 0 ]]; then
  if [[ $LANG != $RCONF_LOCALE && $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Different locale and keyboard settings requires intermediate reboot." | sudo tee --append $FILE_LOG_INSTALLER 
    REBOOT_REQUIRED=1
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No intermidate reboot required." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  GUI_KB_LAYOUT=$(grep "^layout" /home/$USER_USERNAME/.config/lxkeymap.cfg | cut -d'=' -f2 | tr -d '"' | tr -d [:blank:])
  if [[ $LANG != $RCONF_LOCALE && ($XKBLAYOUT != $RCONF_KEYBOARD_LANG || $GUI_KB_LAYOUT != $RCONF_KEYBOARD_LANG) ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Different locale and keyboard settings requires intermediate reboot." | sudo tee --append $FILE_LOG_INSTALLER 
    REBOOT_REQUIRED=1
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No intermidate reboot required." | sudo tee --append $FILE_LOG_INSTALLER
  fi
fi

# Change the locale if it is not already set correctly.
if [[ $LANG != $RCONF_LOCALE ]]; then
  if [[ $SUPPORT_RPI_CONFIG_CMDLINE -ne 0 ]]; then
    # Use raspi-config to change the locale if supported.
    sudo raspi-config nonint do_change_locale "$RCONF_LOCALE"
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully change the locale to [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CHANGE_LOCALE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      if [[ $REBOOT_REQUIRED -ne 1 ]]; then
        REBOOT_REQUIRED=2
      fi
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully changed the locale to [$RCONF_LOCALE] - Reboot required." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CHANGE_LOCALE="Completed"
    fi
  else
    # Comment all the locales in the locale.gen file.
    sudo sed -i "s/^[^#]/# &/" $FILE_LOCALE_GEN
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully uncomment the locale [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CHANGE_LOCALE="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      # Uncomment the locale in the locale.gen file.
      sudo sed -i "s/# $RCONF_LOCALE/$RCONF_LOCALE/" $FILE_LOCALE_GEN
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully uncomment the locale [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_LOCALE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
      else
        # Generate the locale.
        sudo locale-gen
        if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully generate the locale [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CHANGE_LOCALE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
        else
          # Update the locale.
          sudo localectl set-locale LANG=$RCONF_LOCALE
          RET_VAL=$?
          if [[ $RET_VAL -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully change the locale to [$RCONF_LOCALE]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
            STATUS_CHANGE_LOCALE="Error"
            STATUS="Error"
            EXIT_CODE=$EXIT_CODE+4
          else
            if [[ $REBOOT_REQUIRED -ne 1 ]]; then
              REBOOT_REQUIRED=2
            fi
            STATUS_CHANGE_LOCALE="Completed"
            echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully changed the locale to [$RCONF_LOCALE] - Reboot required." | sudo tee --append $FILE_LOG_INSTALLER 
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
      echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully configure the keyboard model to [$RCONF_KEYBOARD_MODEL]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CONFIG_KEYBOARD_MODEL="Error"
      STATUS="Error"
      EXIT_CODE=$EXIT_CODE+4
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully configured the keyboard model to [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CONFIG_KEYBOARD_MODEL="Completed"
    fi
  else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard model because it was already [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CONFIG_KEYBOARD_MODEL="Skipped"
  fi

  if [[ $SUPPORT_RPI_CONFIG_CMDLINE -ne 0 ]]; then
    if [[ $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
      sudo raspi-config nonint do_configure_keyboard "$RCONF_KEYBOARD_LANG"
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully configure the keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully configured the keyboard language to [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
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
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully configure the keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
      else
        sudo service keyboard-setup restart
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully restart the keyboard service with language [$RCONF_KEYBOARD_LANG.] Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
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
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully configured the keyboard language to [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
      STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
    else
      if [[ -z $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+4
      else
        sudo sed -i "/^layout =/c\layout = $RCONF_KEYBOARD_LANG" $PATH_HOME/$USER_USERNAME/$FILE_KEYBOARD_MAP
        RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
          STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
          STATUS="Error"
          EXIT_CODE=$EXIT_CODE+4
        else
          echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Sucessfully set the GUI keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        fi
      fi
    fi
  fi
else
  STATUS_CHANGE_LOCALE="Skipped"
  if [[ $REBOOT_REQUIRED -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language becuase of pending reboot." | sudo tee --append $FILE_LOG_INSTALLER
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard model because it was already [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER 
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER
    if [[ ! -z $GUI_KB_LAYOUT ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing gui keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER 
    fi 
  fi
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
echo "RCONF_OVERSCAN=\"${STATUS_OVERSCAN}\"" >> $FILE_STATUS_RCONF
echo "RCONF_BLANKING=\"${STATUS_BLANKING}\"" >> $FILE_STATUS_RCONF
echo "RCONF_GPU_MEM_SPLIT=\"${STATUS_GPU_MEM_SPLIT}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CHANGE_LOCALE=\"${STATUS_CHANGE_LOCALE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CHANGE_TIME_ZONE=\"${STATUS_CHANGE_TIME_ZONE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CONFIGURE_KEYBOARD=\"${STATUS_CONFIG_KEYBOARD_LANGUAGE}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CONFIGURE_KEYBOARD_MODEL=\"${STATUS_CONFIG_KEYBOARD_MODEL}\"" >> $FILE_STATUS_RCONF
echo "RCONF_CONFIGURE_WIFI_COUNTRY=\"${STATUS_CONFIGURE_WIFI_COUNTRY}\"" >> $FILE_STATUS_RCONF
echo "RCONF_EXPAND_ROOT_FS=\"${STATUS_EXPAND_ROOT_FS}\"" >> $FILE_STATUS_RCONF
echo "RCONF_STATUS=\"${STATUS}\"" >> $FILE_STATUS_RCONF

if [[ $REBOOT_REQUIRED -ne 0 ]]; then
  if [[ $REBOOT_REQUIRED -eq 1 ]]; then
    if ! (grep -q "Installicious Reboot" $FILE_RC_LOCAL); then
      # Add the command before the 'exit 0' line
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Added reboot to next startup." | sudo tee --append $FILE_LOG_INSTALLER 
      sudo sed -i "/^exit 0$/i # Installicious Reboot to $FILE_INSTALLER_RCONF_REBOOT\ncd $PATH_INSTALLICIOUS;sudo bash $PATH_INSTALLICIOUS/$FILE_INSTALLICIOUS --reboot installer $FILE_INSTALLER_RCONF_REBOOT" "$FILE_RC_LOCAL"
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully configure the reboot to run $FILE_INSTALLER_RCONF_REBOOT. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+16
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully configured the reboot to run $FILE_SCRIPT_PROCESS_OPTIONS." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
      fi
    fi
  elif [[ $REBOOT_REQUIRED -eq 2 ]]; then
    if ! (grep -q "Installicious" $FILE_RC_LOCAL); then
      # Add the command before the 'exit 0' line
      sudo sed -i "/^exit 0$/i # Installicious Reboot to $FILE_SCRIPT_PROCESS_OPTIONS\ncd $PATH_INSTALLICIOUS;sudo bash $PATH_INSTALLICIOUS/$FILE_INSTALLICIOUS --reboot script $FILE_SCRIPT_PROCESS_OPTIONS" "$FILE_RC_LOCAL"
      RET_VAL=$?
      if [[ $RET_VAL -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %T.%5N') - ERR! - [$MODULE] Unable to sucessfully configure the reboot to run $FILE_SCRIPT_PROCESS_OPTIONS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
        STATUS="Error"
        EXIT_CODE=$EXIT_CODE+16
      else
        echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Sucessfully configured the reboot to run $FILE_SCRIPT_PROCESS_OPTIONS." | sudo tee --append $FILE_LOG_INSTALLER 
        STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
      fi
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Rebooting with out any additional scripts to be run after reboot." | sudo tee --append $FILE_LOG_INSTALLER 
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Rebooting Raspberry Pi. Additional logs can be found at $FILE_LOG_INSTALLER." | sudo tee --append $FILE_LOG_INSTALLER
  sudo reboot --reboot
fi

exit $EXIT_CODE