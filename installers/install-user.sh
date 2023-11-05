#!/bin/bash

MODULE="Set User"
DESCRIPTION="Creates the new user and deletes the pi user."
PATH_SUDOERS="/etc/sudoers.d" 
FILE_CRON_CURRENT_IP="current-ip"
FILE_CRON_CURRENT_WEATHER="current-weather"
FILE_MOTD="motd.sh"
FILE_MOTD_SMALL="motd-small.sh"
FILE_MOTD_CURRENT_IP="motd-current-ip.sh"
FILE_MOTD_CURRENT_WEATHER="motd-current-weather.sh"
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_USER="config/user.config"

STATUS_CREATED_USER="Not Run"
STATUS_DELETED_PI="Not Run"
STATUS="Not Run"
EXIT_CODE=0

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS." 
  exit 1
fi

# Input Base Variables and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL." 
  exit 1
fi

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

FILE_STATUS_MOTD="$PATH_STATUS/user.status"

# Look for User conf file.
if [[ ! -f $FILE_CONFIG_USER ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_USER." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Input User config and check if it was successful.
source $FILE_CONFIG_USER
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_USER. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Check for User UserName in loaded config file.
if [[ -z $USER_USERNAME ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a User Name in the configuration file $FILE_CONFIG_USER." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Check for User Password in loaded config file.
if [[ -z $USER_PASSWORD || $USER_PASSWORD = "%%User Password%%" ]]; then
echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to find a Password in the file $FILE_CONFIG_USER so using the default Raspberry Pi password." | sudo tee --append $FILE_LOG_INSTALLER
  USER_PASSWORD="raspberry"
fi

if [[ II_CODENAME == "Wheezy" || II_CODENAME == "Jessie" || II_CODENAME == "Stretch" ]]; then
  sudo useradd -m $USER_USERNAME --groups users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,sudo
else
  sudo useradd -m $USER_USERNAME --groups users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
fi

# Set the password
sudo echo "$USER_USERNAME:$USER_PASSWORD" | sudo chpasswd

if [[ $USER_DELETE_PI ]]; then
  # Set the sudo permissions file
  sudo sed -i  "s/$USER_USERNAME /dan /g" $PATH_SUDOERS/010_pi-nopasswd

  # Rename the sudo permissions file
  sudo mv $PATH_SUDOERS/010_pi-nopasswd $PATH_SUDOERS/010-nopasswd

  # Delete the pi user
  sudo deluser -remove-home pi
else
  # Copy the sudo permissions file
  sudo cp $PATH_SUDOERS/010_pi-nopasswd $PATH_SUDOERS/010_$USER_USERNAME-nopasswd
  
  # Set the sudo permissions file
  sudo sed -i "pi /a$USER_USERNAME ALL=(ALL) NOPASSWD: ALL/g" $PATH_SUDOERS/010_$USER_USERNAME-nopasswd
fi

# Logout Pi User
logout
