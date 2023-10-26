#!/bin/bash

MODULE="Install Message of the Day"
DESCRIPTION="Sets the message that shows after a login on SSH session."
PATH_MOTD="/etc/motd.d"
PATH_CRON_DAILY="/etc/cron.daily"
PATH_CRON_HOURLY="/etc/cron.hourly"
FILE_CRON_CURRENT_IP="current-ip"
FILE_CRON_CURRENT_WEATHER="current-weather"
FILE_MOTD="motd.sh"
FILE_MOTD_SMALL="motd-small.sh"
FILE_MOTD_CURRENT_IP="motd-current-ip.sh"
FILE_MOTD_CURRENT_WEATHER="motd-current-weather.sh"
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_MOTD="config/motd.config"
FILE_STATUS_OS_NAME="os.status"
FILE_STATUS_MOTD_NAME="motd.status"
TOKEN_MOTD_NAME="%%MOTD_NAME%%"
TOKEN_MOTD_IP_URL="%%MOTD_IP_URL%%"
TOKEN_MOTD_WEATHER_LOC_CODE="%%MOTD_WEATHER_LOC_CODE%%"
STATUS_MOTD="Not Run"
STATUS_MOTD_SMALL="Not Run"
STATUS="Not Run"
EXIT_CODE=0

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

FILE_STATUS_OS="$PATH_STATUS/$FILE_STATUS_OS_NAME"
FILE_STATUS_MOTD="$PATH_STATUS/$FILE_STATUS_MOTD_NAME"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

## Load Required Variables
if [[ -e $FILE_STATUS_OS ]]; then
  source $FILE_STATUS_OS
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Configuration due to error loading variables. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Configuration due to missing file $FILE_STATUS_OS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

if [[ -z $II_CODENAME ]]; then
  if [[ $II_CODENAME = "Wheezy" || $II_CODENAME = "Jessie" || $II_CODENAME = "Stretch" ]]; then
    SUPPORT_RPI_CONFIG_CMDLINE=0
  else
    SUPPORT_RPI_CONFIG_CMDLINE=1
  fi
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load required OS Configuration due to error loading variables. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Look for MOTD conf file.
if [[ ! -f $FILE_CONFIG_MOTD ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_MOTD." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Input MOTD config and check if it was successful.
source $FILE_CONFIG_MOTD
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_MOTD. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Check for MOTD Name in loaded config file.
if [[ -z $MOTD_NAME ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a MOTD name in the configuration file $FILE_CONFIG_MOTD." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Truncate old MSOD so the text does not appear
sudo truncate -s 0 /etc/motd
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to truncate the default MOTD file /etc/motd. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully truncated the default MOTD file /etc/motd." | sudo tee --append $FILE_LOG_INSTALLER
fi

if [[ ! -d "$PATH_MOTD" ]]; then
  sudo mkdir "$PATH_MOTD"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to create the missing MOTD path $PATH_MOTD. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Error"
    STATUS="Error"
    exit 2
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully created the missing MOTD path $PATH_MOTD." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the MOTD path $PATH_MOTD/$MOTD_NAME." | sudo tee --append $FILE_LOG_INSTALLER
fi

if [[ ! -d "$PATH_MOTD/$MOTD_NAME" ]]; then
  sudo mkdir "$PATH_MOTD/$MOTD_NAME"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to create the missing MOTD name path $PATH_MOTD/$MOTD_NAME. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    STATUS_RC_UPGRADE="Error"
    STATUS="Error"
    exit 2
  else
    echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Successfully created the missing MOTD name path $PATH_MOTD/$MOTD_NAME." | sudo tee --append $FILE_LOG_INSTALLER
  fi
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Found the MOTD name path $PATH_MOTD/$MOTD_NAME." | sudo tee --append $FILE_LOG_INSTALLER
fi

# Copy the MOTD files to the MOTD path.
sudo cp -f "$PATH_RESOURCES/$FILE_MOTD" $PATH_MOTD/$MOTD_NAME/$FILE_MOTD
sudo chmod 755 "$PATH_MOTD/$MOTD_NAME/$FILE_MOTD"
sudo sed -i "s/$TOKEN_MOTD_NAME/$MOTD_NAME/g" $PATH_MOTD/$MOTD_NAME/$FILE_MOTD

# Copy the Small MOTD files to the MOTD path if Lite OS (Not needed with Pixel Desktop).
if [[ $II_OS_LEVEL = "Lite" ]]; then
  sudo cp -f "$PATH_RESOURCES/$FILE_MOTD_SMALL" $PATH_MOTD/$MOTD_NAME/$FILE_MOTD_SMALL
  sudo chmod 755 "$PATH_MOTD/$MOTD_NAME/$FILE_MOTD_SMALL"
  sudo sed -i "s/$TOKEN_MOTD_NAME/$MOTD_NAME/g" $PATH_MOTD/$MOTD_NAME/$FILE_MOTD_SMALL
fi

# Check for the existence of the current IP MOTD file.
sudo cp -f "$PATH_RESOURCES/$FILE_MOTD_CURRENT_IP" $PATH_CRON_DAILY/$FILE_CRON_CURRENT_IP
sudo chmod 755 "$PATH_CRON_DAILY/$FILE_CRON_CURRENT_IP"
sudo sed -i "s/$TOKEN_MOTD_NAME/$MOTD_NAME/g" $PATH_CRON_DAILY/$FILE_CRON_CURRENT_IP
sudo sed -i "s|$TOKEN_MOTD_IP_URL|$MOTD_IP_URL|g" $PATH_CRON_DAILY/$FILE_CRON_CURRENT_IP
sudo $"$PATH_CRON_DAILY/$FILE_CRON_CURRENT_IP"

# Check for the existence of the current Weather MOTD file.
sudo cp -f "$PATH_RESOURCES/$FILE_MOTD_CURRENT_WEATHER" $PATH_CRON_HOURLY/$FILE_CRON_CURRENT_WEATHER
sudo chmod 755 "$PATH_CRON_HOURLY/$FILE_CRON_CURRENT_WEATHER"
sudo sed -i "s/$TOKEN_MOTD_NAME/$MOTD_NAME/g" $PATH_CRON_HOURLY/$FILE_CRON_CURRENT_WEATHER
sudo sed -i "s/$TOKEN_MOTD_WEATHER_LOC_CODE/$MOTD_WEATHER_LOC_CODE/g" $PATH_CRON_HOURLY/$FILE_CRON_CURRENT_WEATHER
sudo $"$PATH_CRON_HOURLY/$FILE_CRON_CURRENT_WEATHER"

# Update the tokens in the Current IP MOTD file.
# Update the tokens in the Current Weather MOTD file.

# Prevent defauly MOTD from running. if Jessie or Wheezy
if [[ $II_CODENAME = "Jessie" || $II_CODENAME = "Wheezy" ]]; then
  if ! grep -q "# uname -snrvm > /var/run/motd.dynamic" /etc/init.d/motd; then
    sudo sed -i "s/\(uname -snrvm > \/var\/run\/motd.dynamic\)/# \1/" /etc/init.d/motd
    # Add a line in after that adds a : to prevent empty function.
    sudo sed -i "/# uname -snrvm >/a\        :" /etc/init.d/motd
  fi
else
  sudo sed -i "s/\(uname -snrvm\)/# \1/" /etc/update-motd.d/10-uname
fi

# Remove the last logn info from SSH
sudo sed -i "s/^\s*#\?\s*PrintLastLog \(yes\|no\)/PrintLastLog no/" /etc/ssh/sshd_config

# Remove the last login info for TTY Console
sudo sed -i "/^\s*session\s*optional\s*pam_lastlog.so/s/^\(\s*\)/#\1/" /etc/pam.d/login


# Small MOTD will not work with Pixel Desktop
if [[ $II_OS_LEVEL = "Lite" ]]; then
  if ! grep -q "# Show MOTD on start or login." /etc/profile; then
    sudo echo >> /etc/profile
    sudo echo "# Show MOTD on start or login." >> /etc/profile
    sudo echo "# Check if screen is big enough to display large message" >> /etc/profile
    sudo echo "read screenWidth <<< \$(stty -a | awk 'NR==1 { print \$7 }')" >> /etc/profile
    sudo echo "intWidth=\${screenWidth::-1}" >> /etc/profile
    sudo echo "if [[ intWidth -gt 79 ]]; then" >> /etc/profile
    sudo echo "  /etc/motd.d/$MOTD_NAME/motd.sh" >> /etc/profile
    sudo echo "else" >> /etc/profile
    sudo echo "  /etc/motd.d/$MOTD_NAME/motd-small.sh" >> /etc/profile
    sudo echo "fi" >> /etc/profile
  fi
else
  # Enable MOTD in Profile if not added.
  if ! grep -q "# Show MOTD on start or login." /etc/profile; then
    sudo echo >> /etc/profile
    sudo echo "# Show MOTD on start or login." >> /etc/profile
    sudo echo "/etc/motd.d/$MOTD_NAME/motd.sh" >> /etc/profile
  fi
fi

sudo service ssh restart

STATUS_MOTD="Completed"
STATUS_MOTD_SMALL="Completed"

# Write status
STATUS="Completed"

CURRENT_RUN="$(date '+%Y-%m-%d %T.%5N')"

# Remove existing status file.
if [[ -e $FILE_STATUS_MOTD ]]; then
  sudo rm --force "$FILE_STATUS_MOTD"
fi

echo "MOTD_LAST_RUN=\"${CURRENT_RUN}\"" > $FILE_STATUS_MOTD
echo "MOTD_MOTD_STATUS=\"${STATUS_MOTD}\"" >> $FILE_STATUS_MOTD
echo "MOTD_SMALL_STATUS=\"${STATUS_MOTD_SMALL}\"" >> $FILE_STATUS_MOTD
echo "MOTD_STATUS=\"${STATUS}\"" >> $FILE_STATUS_MOTD

if [[ $II_CODENAME = "Wheezy" ]]; then
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "[ \e[0;32mok\e[0m ] Installicious successfully customized the Message of the Day for the Raspberry Pi."
  else
    echo -e "[\e[0;31mFAIL\e[0m] Installicious could not customize the Message of the Day for the Raspberry Pi. Error Code: $EXIT_CODE."
  fi
else
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "[  \e[1;32mOK\e[0m  ] Installicious successfully customized the Message of the Day for the Raspberry Pi."
  else
    echo -e "[ \e[1;31mFAIL\e[0m ] Installicious could not customize the Message of the Day for the Raspberry Pi. Error Code: $EXIT_CODE."
  fi
fi

exit $EXIT_CODE