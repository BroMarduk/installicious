#!/bin/bash

# === II_MANIFEST_BEGIN ===
II_ID="rconf"
II_TITLE="Raspberry Pi Configuration"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="conditional"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="RCONF_LOCALE RCONF_TIME_ZONE RCONF_KEYBOARD_LANG RCONF_KEYBOARD_MODEL RCONF_WIFI_COUNTRY RCONF_BOOT_BEHAVIOUR"
# === II_MANIFEST_END ===

# Internal log tag (kept for back-compat with the existing echo + sudo tee
# pattern throughout this file; full migration to lib/log.sh is deferred).
MODULE="Install Raspi-Config"
DESCRIPTION="Sets the basic settings for raspi-config."

# New-framework helpers used by the reboot/resume path (see end of file).
# These are sourced lazily so the existing config-source block below still
# wins for PATH_LOGS, PATH_STATUS, etc.
source lib/log.sh   2>/dev/null || true
source lib/status.sh 2>/dev/null || true
source lib/state.sh  2>/dev/null || true
source lib/reboot.sh 2>/dev/null || true
PATH_ZONE_INFO="/usr/share/zoneinfo"
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
FILE_LOCALE_CONFIG="/etc/default/locale"
FILE_KEYBOARD_CONFIG="/etc/default/keyboard"
FILE_LOCALE_GEN="/etc/locale.gen"
FILE_CONSOLE_BLANKING="/sys/module/kernel/parameters/consoleblank"
FILE_TIME_ZONE="/etc/timezone"
FILE_WPA_SUPPLICANT="/etc/wpa_supplicant/wpa_supplicant.conf"
FILE_LOCAL_TIME="/etc/localtime"
FILE_LIGHTDM_CONFIG="/etc/lightdm/lightdm.conf"
FILE_RASPI_CONFIG="/usr/bin/raspi-config"
EXIT_REBOOT=255
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

# Apply user edits from the menu_edit_config screen (Phase 2). Sourced after
# baseline configs so the user's chosen values win for the duration of the run.
declare -F state_apply_menu_overrides >/dev/null && state_apply_menu_overrides

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

# Ensure raspi-config is installed (replaces the legacy
# dependencies/raspi-config-up.sh shim with lib/apt.sh's idempotent helper).
if declare -F apt_ensure_installed >/dev/null; then
  apt_ensure_installed raspi-config
  RET_VAL=$?
else
  sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes raspi-config
  RET_VAL=$?
fi
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to check for or install package raspi-config. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
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

# Boot config path: file-existence based, matching the canonical detection in
# upstream raspi-config. Works for Bullseye (/boot/), Bookworm (/boot/firmware/)
# and Trixie (/boot/firmware/) without needing a per-OS branch.
if [[ -e /boot/firmware/config.txt ]]; then
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

# Bullseye/Bookworm/Trixie all support the modern non-interactive raspi-config
# CLI directly; the legacy support-tier gating is gone.

# Change 'Localisation' to 'Localization' in raspi-config file.
if sudo grep -q "Localisation " "$FILE_RASPI_CONFIG"; then
  sed -i "s/Localisation /Localization /" $FILE_RASPI_CONFIG
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to apply full English mode to raspi-config. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_UPDATE_RASPI_CONFIG="Warning"
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully applied full English mode to the raspi-config file." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_UPDATE_RASPI_CONFIG="Completed"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Raspi-config file already current and in full English mode." | sudo tee --append $FILE_LOG_INSTALLER
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
  sudo raspi-config nonint do_overscan $RCONF_OVERSCAN
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
CURRENT_BLANKING=$(sudo raspi-config nonint get_blanking)
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully get the current screen blanking configuration. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_BLANKING="Error"
  STATUS="Error"
  EXIT_CODE=$((EXIT_CODE+4))
else
  if [[ $CURRENT_BLANKING != $RCONF_BLANKING ]]; then
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
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Screen blanking already set to [$RCONF_BLANKING]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING="Skipped"
  fi
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
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the console blanking change to [$RCONF_BLANKING_SECONDS]." | sudo tee --append $FILE_LOG_INSTALLER
      REBOOT_REQUIRED=2
      STATUS_BLANKING_CONSOLE="Completed"
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The console blanking is already set to [$RCONF_BLANKING_SECONDS]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_BLANKING_CONSOLE="Skipped"
  fi
fi

# Configure the GPU memory split.
# Pi 5 firmware does not allocate GPU memory on behalf of the OS, so the
# gpu_mem= setting in config.txt is a no-op there (per the Pi legacy config.txt
# docs). Skip entirely on Pi 5+; on Pi 1-4 the manual sed is still the
# supported path since raspi-config dropped do_memory_split in Bookworm/Trixie.
if [[ ${II_MODEL_NUM:-0} -ge 5 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipping GPU memory split: Pi 5+ firmware does not honor gpu_mem." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_GPU_MEM_SPLIT="Skipped"
else
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
    # Set the GPU memory split via direct config.txt edit. Modern raspi-config
    # on Bookworm dropped do_memory_split, and Trixie follows; manual sed of
    # /boot/firmware/config.txt is the supported path on all our target OSes.
    if grep -q "^#gpu_mem" $FILE_BOOT_CONFIG; then
      sudo sed -i "s/^#gpu_mem=.*/gpu_mem=$GPU_MEM_SPLIT/" $FILE_BOOT_CONFIG
    elif grep -q "^gpu_mem" $FILE_BOOT_CONFIG; then
      sudo sed -i "s/^gpu_mem=.*/gpu_mem=$GPU_MEM_SPLIT/" $FILE_BOOT_CONFIG
    else
      echo "# uncomment to force a gpu_mem size for the GPU" | sudo tee -a $FILE_BOOT_CONFIG > /dev/null
      echo "gpu_mem=$GPU_MEM_SPLIT" | sudo tee -a $FILE_BOOT_CONFIG > /dev/null
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
fi

# Configure the time zone via raspi-config (supported on all target OSes).
TIME_ZONE=$(timedatectl | grep "Time zone" | awk '{print $3}')
if [[ $TIME_ZONE = $RCONF_TIME_ZONE ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] The time zone is already set to [$RCONF_TIME_ZONE]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CHANGE_TIME_ZONE="Skipped"
else
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
fi

# Configure the WiFi country via raspi-config (supported on all target OSes).
CURRENT_WIFI_COUNTRY=$(sudo raspi-config nonint get_wifi_country)
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully get the current WiFi country configuration. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CONFIGURE_WIFI_COUNTRY="Error"
  STATUS="Error"
  EXIT_CODE=$((EXIT_CODE+4))
else
  if [[ $CURRENT_WIFI_COUNTRY != $RCONF_WIFI_COUNTRY ]]; then
    sudo raspi-config nonint do_wifi_country "$RCONF_WIFI_COUNTRY" >/dev/null
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to successfully complete the WiFi country configuration to [$RCONF_WIFI_COUNTRY]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      STATUS_CONFIGURE_WIFI_COUNTRY="Error"
      STATUS="Error"
      EXIT_CODE=$((EXIT_CODE+4))
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully completed the WiFi country configuration to [$RCONF_WIFI_COUNTRY]." | sudo tee --append $FILE_LOG_INSTALLER
      REBOOT_REQUIRED=2
      STATUS_CONFIGURE_WIFI_COUNTRY="Completed"
    fi
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] WiFi country already set to [$RCONF_WIFI_COUNTRY]. Skipping configuration." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CONFIGURE_WIFI_COUNTRY="Skipped"
  fi
fi

# Configure the Locale and Keyboard settings.
# Modern raspi-config supports do_change_locale + do_configure_keyboard on all
# target OSes. The keyboard layout depends on the locale being active, so when
# both are changing we set REBOOT_REQUIRED=1 to flag an intermediate reboot
# (handled by the systemd-resume mechanism — install-rconf re-runs after the
# reboot and completes the keyboard layout step).
source "$FILE_LOCALE_CONFIG"
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load the current locale. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CHANGE_LOCALE="Error"
  STATUS="Error"
  EXIT_CODE=$((EXIT_CODE+8))
fi

source "$FILE_KEYBOARD_CONFIG"
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load the current keyboard settings. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
  STATUS="Error"
  EXIT_CODE=$((EXIT_CODE+8))
fi

# If both locale and keyboard layout are changing, schedule the keyboard
# layout step for after the reboot (the new locale must be active first).
if [[ $LANG != $RCONF_LOCALE && $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Different locale and keyboard settings requires intermediate reboot." | sudo tee --append $FILE_LOG_INSTALLER
  REBOOT_REQUIRED=1
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] No intermediate reboot required." | sudo tee --append $FILE_LOG_INSTALLER
fi

# Change the locale if it is not already set correctly.
if [[ $LANG != $RCONF_LOCALE ]]; then
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
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully changed the locale to [$RCONF_LOCALE]. Reboot required." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CHANGE_LOCALE="Completed"
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing locale because it was already [$RCONF_LOCALE]." | sudo tee --append $FILE_LOG_INSTALLER
  STATUS_CHANGE_LOCALE="Skipped"
fi

# Configure keyboard model + layout when there's no pending reboot. On a
# locale-change cycle this runs on the post-reboot pass, when the new locale
# is active and the keyboard layout call can succeed cleanly.
if [[ $REBOOT_REQUIRED -eq 0 && $XKBLAYOUT != $RCONF_KEYBOARD_LANG ]]; then
  if [[ $XKBMODEL != $RCONF_KEYBOARD_MODEL ]]; then
    sudo sed -i "s/XKBMODEL=\".*\"/XKBMODEL=\"$RCONF_KEYBOARD_MODEL\"/" "$FILE_KEYBOARD_CONFIG"
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to configure the keyboard model to [$RCONF_KEYBOARD_MODEL]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
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

  sudo raspi-config nonint do_configure_keyboard "$RCONF_KEYBOARD_LANG"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to configure the keyboard language to [$RCONF_KEYBOARD_LANG]. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CONFIG_KEYBOARD_LANGUAGE="Error"
    STATUS="Error"
    EXIT_CODE=$((EXIT_CODE+4))
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully configured the keyboard language to [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_CONFIG_KEYBOARD_LANGUAGE="Completed"
  fi
else
  if [[ $REBOOT_REQUIRED -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because of pending reboot (will run on resume)." | sudo tee --append $FILE_LOG_INSTALLER
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard model because it was already [$RCONF_KEYBOARD_MODEL]." | sudo tee --append $FILE_LOG_INSTALLER
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Skipped changing keyboard language because it was already [$RCONF_KEYBOARD_LANG]." | sudo tee --append $FILE_LOG_INSTALLER
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

if [[ $EXIT_CODE -eq 0 && $REBOOT_REQUIRED -ne 0 ]]; then
  # Replaces the legacy /etc/rc.local sed-injection: lib/reboot.sh saves the
  # scheduler queue state (so resume picks up after the reboot) and triggers
  # systemd-driven shutdown. Re-running install-rconf after the reboot is what
  # completes any setting that needed an active locale (keyboard layout etc.) —
  # the legacy install-rconf-reboot.sh's logic is already covered by this
  # script's own keyboard-config block on second pass.
  if [[ $REBOOT_REQUIRED -eq 1 ]]; then
    REASON="rconf locale change requires reboot before keyboard layout can apply"
  else
    REASON="rconf settings change requires reboot to take effect"
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] $REASON. Triggering systemd-resume reboot." | sudo tee --append $FILE_LOG_INSTALLER

  if declare -F request_reboot >/dev/null; then
    request_reboot "$REASON" "rconf"
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] lib/reboot.sh not loaded; cannot request reboot." | sudo tee --append $FILE_LOG_INSTALLER
    EXIT_CODE=$((EXIT_CODE+16))
    exit $EXIT_CODE
  fi
  exit $EXIT_REBOOT
fi

if [[ $EXIT_CODE -eq 0 ]]; then
  echo -e "[  \e[0;32mOK\e[0m  ] Installicious successfully completed the configuration of the Raspberry Pi."
else
  echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not complete the configuration of the Raspberry Pi. Error Code: $EXIT_CODE."
fi

exit $EXIT_CODE