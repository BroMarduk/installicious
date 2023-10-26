#!/bin/bash

## The main file to run for Installicious.
MODULE="Installicious Main"
DESCRIPTION="The starting point for Installicious. Run this first and watch the magic happen."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
CHANGE_LOCALE=0
REBOOT_REQUIRED=0

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS." 
  exit 1
fi

# Input Base Variables and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

# Make sure the logging directory variable can be found.
if [[ -z $PATH_LOGS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find a value for the logging directory in the configuration $FILE_CONFIG_INSTALLICIOUS." 
  exit 1
else
  # Check for logs directory as it must exist
  if [[ ! -d $PATH_LOGS ]]; then
    mkdir -p "$PATH_LOGS";
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to create the logs directory $PATH_LOGS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL." 
      exit 1
    fi
  fi
fi

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# Load the command line parameters if there are any and check for reboot
if [[ ! -z $* ]]; then
  REBOOT=$1
  INSTALLERTYPE=$2
  NEXTFILE=$3

  # Check for Reboot mode and run back to the installer if a reboot
  if [[ "${REBOOT,,}" = "--reboot" && ! -z $INSTALLERTYPE && ! -z $NEXTFILE ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious processing reboot type $INSTALLERTYPE for file $NEXTFILE.sh." | sudo tee --append $FILE_LOG_INSTALLER
    # Remove the reboot reference comment and next line containing the script from the rc.local file.
    sudo sed -i "/# Installicious Reboot/{N;d;}" /etc/rc.local
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable remove reboot reference comment from the rc.local file. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      exit 1
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Removed reboot reference from the rc.local file." | sudo tee --append $FILE_LOG_INSTALLER
    fi
    if [[ "${INSTALLERTYPE,,}" = "script" ]]; then
      bash "$PATH_SCRIPTS/$NEXTFILE.sh" $REBOOT
      RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to process reboot type $INSTALLERTYPE for file $NEXTFILE.sh" Error Code: $RET_VAL.. | sudo tee --append $FILE_LOG_INSTALLER
          exit 1
        fi
      exit 0
    elif [[ "${INSTALLERTYPE,,}" = "installer" ]]; then
      bash "$PATH_INSTALLERS/$NEXTFILE.sh" $REBOOT
      RET_VAL=$?
        if [[ $RET_VAL -ne 0 ]]; then
          echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to process reboot type $INSTALLERTYPE for file $NEXTFILE.sh". Error Code: $RET_VAL. | sudo tee --append $FILE_LOG_INSTALLER
          exit 1
        fi
      exit 0
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to process reboot type $INSTALLERTYPE for file $NEXTFILE.sh". | sudo tee --append $FILE_LOG_INSTALLER
      exit 1
    fi
  fi
fi

# Create the log file for this run of Installicious by outputting new file which will overwrite last.
if [[ -e $FILE_LOG_INSTALLER ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installer log created." | sudo tee "$FILE_LOG_INSTALLER"
fi

# Make sure the scripts directory variable can be found.
if [[ -z $PATH_SCRIPTS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the scripts directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for scripts directory as it must exist.
  if [[ ! -d $PATH_SCRIPTS ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the scripts directory $PATH_SCRIPTS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Make sure the installers directory variable can be found.
if [[ -z $PATH_INSTALLERS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the installers directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for scripts directory as it must exist.
  if [[ ! -d $PATH_INSTALLERS ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the scripts installers $PATH_INSTALLERS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Make sure the dependencies directory variable can be found.
if [[ -z $PATH_DEPENDENCIES ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the dependencies directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for dependencies directory as it must exist.
  if [[ ! -d $PATH_DEPENDENCIES ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the dependencies directory $PATH_DEPENDENCIES specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Make sure the config directory variable can be found.
if [[ -z $PATH_CONFIG ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the config directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for config directory as it must exist.
  if [[ ! -d $PATH_CONFIG ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the config directory $PATH_CONFIG specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Make sure the status directory variable can be found.
if [[ -z $PATH_STATUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the status directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for status directory and create if it does not exist.
  if [[ ! -d $PATH_STATUS ]]; then
    mkdir -p "$PATH_STATUS";
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to create the status directory $PATH_STATUS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      exit 1
    fi
  else
    # If it exists, remove any existing status files but will keep status.time files.
    sudo rm --force "$PATH_STATUS"/*.status
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to delete the existing status files in $PATH_STATUS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
      exit 1
    else
      echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Deleted the existing status files in $PATH_STATUS." | sudo tee --append $FILE_LOG_INSTALLER
    fi
  fi
fi

FILE_STATUS_OS="$PATH_STATUS/os.status"

## Current User
CURRENTUSER="$(whoami)"

## Check Dependencies
WHIPTAIL_RESULT=$(sudo bash "$PATH_DEPENDENCIES/whiptail.sh")
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to check for or install package Whiptail. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Reads the Model of the Raspberry Pi
read PIMODEL < /proc/device-tree/model

## Check for Full vs Lite
if [[ -f "/usr/bin/startx" ]]; then
  OSLEVEL="GUI"
  OSLEVELNAME=""
else
  OSLEVEL="Lite"
  OSLEVELNAME=" Lite "
fi

## Reads the Debian Full Version
read DEBIANVERSION < /etc/debian_version

## Reads the OS Release Information
. /etc/os-release

## Makes the Version Codename start with an upper for asthetics
CODENAME=${VERSION_CODENAME^}

if [[ -z $CODENAME ]]; then
  read DEBIAN_VERSION < /etc/debian_version
  NUM_VERSION=${DEBIAN_VERSION%%.*}
  if [[ $NUM_VERSION -gt 12 ]]; then
    CODENAME="Trixie"
  elif [[ $NUM_VERSION -eq 12 ]]; then
    CODENAME="Bookworm"
  elif [[ $NUM_VERSION -eq 11 ]]; then
    CODENAME="Bullseye"
  elif [[ $NUM_VERSION -eq 10 ]]; then
    CODENAME="Buster"
  elif [[ $NUM_VERSION -eq 9 ]]; then
    CODENAME="Stretch"
  elif [[ $NUM_VERSION -eq 8 ]]; then
    CODENAME="Jessie"
  elif [[ $NUM_VERSION -eq 7 ]]; then
    CODENAME="Wheezy"
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to determine the OS Code Name for version $VERSION ($NUM_VERSION)." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

## Get OS 32/64 bit version
BITS=$(getconf LONG_BIT)

## Reads the Pi Revision without the bits for OTP and overclocking. Only the bottom 24 bits matter.
PRE_REVISION=$(cat /proc/cpuinfo | grep 'Revision' | awk ' {print $3}' | sed -E 's/.*(.{6})/\1/' | sed 's/^0*//')

## Pad a 0 to the front of the revision if it is less than 4 characters long.
if [[ ! -z $PRE_REVISION ]]; then
  REVISION=$(printf "%04x" "0x$PRE_REVISION")
else
  echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to detect revision of hardware. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Sets the total memory based on the revision
case $REVISION in
  #  Beta   Raspberry Pi Beta
  #  0002   Raspberry Pi 1 B 1.0
  #  0003   Raspberry Pi 1 B 1.0 (Fuses Mod)
  #  0004   Raspberry Pi 1 B 2.0 (Sony)
  #  0005   Raspberry Pi 1 B 2.0 (Qisda)
  #  0006   Raspberry Pi 1 B 2.0 (Egoman)
  #  0007   Raspberry Pi 1 A 2.0 (Egoman)
  #  0008   Raspberry Pi 1 A 2.0 (Sony)
  #  0009   Raspberry Pi 1 A 2.0 (Qisda)
  #  0012   Raspberry Pi 1 A+ 1.1 (Sony)
  #  0015   Raspberry Pi 1 A+ 1.1 (Embest) - could have 512 but going with low here.
  "Beta" | "0002" | "0003" | "0004" | "0005" | "0006" | "0007" | "0008" | "0009" | "0012" | "0015")
    MEMORY="256";;
  #  000d   Raspberry Pi 1 B 2.0 (Egoman)
  #  000e   Raspberry Pi 1 B 2.0 (Sony)
  #  000f   Raspberry Pi 1 B 2.0 (Qisda)
  #  0010   Raspberry Pi 1 B+ 1.0 (Sony)
  #  0011   Raspberry Pi Compute Module 1 1.0 (Sony)
  #  0013   Raspberry Pi 1 B+ 1.2 (Embest)
  #  0014   Raspberry Pi Compute Module 1 1.0 (Embest)
  #  900021 Raspberry Pi 1 A+ 1.1 (Sony)
  #  900032 Raspberry Pi 1 B+ 1.2 (Sony)
  #  900092 Raspberry Pi Zero 1.2 (Sony)
  #  900093 Raspberry Pi Zero 1.3 (Sony)
  #  920093 Raspberry Pi Zero 1.3 (Embest)
  #  9000c1 Raspberry Pi Zero W 1.1 (Sony)
  #  9020e0 Raspberry Pi 3 A+ 1.0 (Sony)
  #  902120 Raspberry Pi Zero 2 W 1.0 (Sony)
  "000d" | "000e" | "000f" | "0010" | "0011" | "0013" | "0014" | "900021" | "900032" | "900092" | "900093" | "920093" | "9000c1" | "9020e0" | "902120")
    MEMORY="512";;
  #  a01040 Raspberry Pi 2 B 1.0 (Sony)
  #  a01041 Raspberry Pi 2 B 1.1 (Sony)
  #  a21041 Raspberry Pi 2 B 1.1 (Embest)
  #  a22042 Raspberry Pi 2 B 1.2 (Embest)
  #  a02082 Raspberry Pi 3 B 1.2 (Sony)
  #  a020a0 Raspberry Pi Compute Module 3 1.0 (Sony) - also Compute Module 3 Lite
  #  a22082 Raspberry Pi 3 B 1.2 (Embest)
  #  a32082 Raspberry Pi 3 B 1.2 (Sony Japan)
  #  a020d3 Raspberry Pi 3 B+ 1.3 (Sony)
  #  a02100 Raspberry Pi Compute Module 3+ 1.0 (Sony)
  #  a03111 Raspberry Pi 4 B 1.1 (Sony)
  #  a03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  "a01040" | "a01041" | "a21041" | "a22042" | "a02082" | "a020a0" | "a22082" | "a32082" | "a020d3" | "a02100" | "a03111" | "a03140")
    MEMORY="1024";;
  #  b03111 Raspberry Pi 4 B 1.1 (Sony)
  #  b03112 Raspberry Pi 4 B 1.2 (Sony)
  #  b03114 Raspberry Pi 4 B 1.4 (Sony)
  #  b03115 Raspberry Pi 4 B 1.5 (Sony)
  #  b03130 Raspberry Pi 400 1.0 (Sony)
  #  b03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  "b03111" | "b03112" | "b03114" | "b03115" | "b03140")
    MEMORY="2048";;
  #  c03111 Raspberry Pi 4 B 1.1 (Sony)
  #  c03112 Raspberry Pi 4 B 1.2 (Sony)
  #  c03114 Raspberry Pi 4 B 1.4 (Sony)
  #  c03115 Raspberry Pi 4 B 1.5 (Sony)
  #  c03130 Raspberry Pi 400 1.0 (Sony)
  #  c03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  #  c04100 Raspberry Pi 5 B 1.0 (Sony)
  "c03111" | "c03112" | "c03114" | "c03115" | "c03130" | "c03140" | "c04100")
    MEMORY="4096";;
  #  d03114 Raspberry Pi 4 B 1.4 (Sony)
  #  d03115 Raspberry Pi 4 B 1.5 (Sony)
  #  d03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  #  d04100 Raspberry Pi 5 B 1.0 (Sony)
  "d03114" | "d03115" | "d03140" | "d04100")
    MEMORY="8192";;
  *)
    MEMORY="Unknown";;
esac

## Writes out the version information to the os.conf file.
echo "II_MODEL=\"${PIMODEL}\"" > $FILE_STATUS_OS
echo "II_DEBIAN_VERSION=\"${DEBIANVERSION}\"" >> $FILE_STATUS_OS
echo "II_CODENAME=\"${CODENAME}\"" >> $FILE_STATUS_OS
echo "II_VERSION_NAME=\"${NAME}\"" >> $FILE_STATUS_OS
echo "II_OS_LEVEL=\"${OSLEVEL}\"" >> $FILE_STATUS_OS
echo "II_OS_BITS=\"${BITS}\"" >> $FILE_STATUS_OS
echo "II_REVISION=\"${REVISION}\"" >> $FILE_STATUS_OS
echo "II_MEMORY=\"${MEMORY}\"" >> $FILE_STATUS_OS
echo "II_FULL_NAME=\"${NAME} ${DEBIANVERSION}${OSLEVELNAME} (${CODENAME})\"" >> $FILE_STATUS_OS
echo "II_INSTALLICIOUS_PATH=\"${0}\"" >> $FILE_STATUS_OS

## Load Required Variables
source $FILE_STATUS_OS

if (whiptail --title "$MODULE" --defaultno --no-button "Cancel" --yes-button "OK" --yesno "Do you want to setup $MODULE? $DESCRIPTION\n\n$II_MODEL with $II_FULL_NAME" 12 80) then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious started by user $CURRENTUSER" | sudo tee --append $FILE_LOG_INSTALLER
  bash "$PATH_SCRIPTS/options.sh"
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious canceled by user $CURRENTUSER" | sudo tee --append $FILE_LOG_INSTALLER
fi
