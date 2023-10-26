#!/bin/bash

MODULE="Bash Updates"
DESCRIPTION="Some Bash shell updates to make commands work a bit better."
PATH_HOME="/home"
PATH_ROOT="/root"
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
FILE_CONFIG_USER="config/user.config"
FILE_STATUS_OS_NAME="os.status"
FILE_BASHRC=".bashrc"
STATUS_BASH_ROOT="Not Run"
STATUS_BASH_USER="Not Run"
STATUS="Not Run"
EXIT_CODE=0

# Look for installicious conf file.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

## Input installicious config and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

# Look for user conf file.
if [[ ! -f $FILE_CONFIG_USER ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to find the configuration file $FILE_CONFIG_USER." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Input user config and check if it was successful.
source $FILE_CONFIG_USER
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - CRIT - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_USER." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

FILE_STATUS_BASH="$PATH_STATUS/bash.status"

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# No Dependencies

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

# Update Root User's Bash Prompt
sudo sed -i "s/^# force_color_prompt=yes/force_color_prompt=yes/" $PATH_ROOT/$FILE_BASHRC

if [[ -z $(sudo grep "PS1='\${debian_chroot:+(\$debian_chroot)}\\\033\[01;31m\\\]\\\u@\\\h\\\033\[00m\\\\]:\\\033\[01;34m\\\]\\\w " /root/$FILE_BASHRC) ]]; then
  sudo sed -i "/# PS1='\${debian_chroot:+(\$debian_chroot)}\\\\h:\\\\w\\\\\$ '/a \PS1='\${debian_chroot:+(\$debian_chroot)}\\\\033[01;31m\\\\]\\\\u@\\\\h\\\\033[00m\\\\]:\\\\033[01;34m\\\\]\\\\w \\\\\$\\\\033[00m\\\\] '" /root/$FILE_BASHRC
fi

sudo sed -i "s/^# export LS_OPTIONS01CHWURSiD!='--color=auto'/export LS_OPTIONS='--color=auto'/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# eval \"\$(dircolors)\"/eval \"\$(dircolors)\"/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# alias ls='ls \$LS_OPTIONS'/alias ls='ls \$LS_OPTIONS'/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# alias ll='ls \$LS_OPTIONS -l'/alias ll='ls \$LS_OPTIONS -l'/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# alias l='ls \$LS_OPTIONS -lA'/alias l='ls \$LS_OPTIONS -lA'/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# alias rm='rm -i'/alias rm='rm -i'/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# alias cp='cp -i'/alias cp='cp -i'/" $PATH_ROOT/$FILE_BASHRC
sudo sed -i "s/^# alias mv='mv -i'/alias mv='mv -i'/" $PATH_ROOT/$FILE_BASHRC

if [[ -z $(sudo grep "alias dir='ls \$LS_OPTIONS -la'" $PATH_ROOT/$FILE_BASHRC) ]]; then
  sudo sed -i "/alias l='ls \$LS_OPTIONS -lA'/a alias dir='ls \$LS_OPTIONS -la'" $PATH_ROOT/$FILE_BASHRC
fi

sudo sed -i "s/^#$//" $PATH_ROOT/$FILE_BASHRC

STATUS_BASH_ROOT="Completed"

# Update Pi User's Bash Prompt
sudo sed -i "s/^# force_color_prompt=yes/force_color_prompt=yes/" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
sudo sed -i "s/^    #alias dir='dir --color=auto'/    alias dir='ls -la --color=auto'/" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
sudo sed -i "/^    #alias vdir='vdir --color=auto'/{n; d;}" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
sudo sed -i "s/^    #alias vdir='vdir --color=auto'/    alias vdir='vdir --color=auto'/" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
sudo sed -i "s/^#alias ll='ls -l'/alias ll='ls -l'/" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
sudo sed -i "s/^#alias la='ls -A'/alias la='ls -A'/" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
sudo sed -i "s/^#alias l='ls -CF'/alias l='ls -CF'/" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC

if [[ -z $(grep "alias sudo='sudo '" $PATH_HOME/$USER_USERNAME/$FILE_BASHRC) ]]; then
  sudo echo >> $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
  sudo echo "# Enable aliases for sudo" >> $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
  sudo echo "alias sudo='sudo '" >> $PATH_HOME/$USER_USERNAME/$FILE_BASHRC
fi

STATUS_BASH_USER="Completed"

# Write status
STATUS="Completed"

CURRENT_RUN="$(date '+%Y-%m-%d %T.%5N')"

# Remove existing status file.
if [[ -e $FILE_STATUS_BASH ]]; then
  sudo rm --force "$FILE_STATUS_BASH"
fi

echo "BASH_LAST_RUN=\"${CURRENT_RUN}\"" > $FILE_STATUS_BASH
echo "BASH_ROOT=\"${STATUS_BASH_ROOT}\"" >> $FILE_STATUS_BASH
echo "BASH_USER=\"${STATUS_BASH_USER}\"" >> $FILE_STATUS_BASH
echo "BASH_STATUS=\"${STATUS}\"" >> $FILE_STATUS_BASH

if [[ $II_CODENAME = "Wheezy" ]]; then
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "[ \e[0;32mok\e[0m ] Installicious successfully customized the bash customizations for the Raspberry Pi."
  else
    echo -e "[\e[0;31mFAIL\e[0m] Installicious could not customize the bash customizations for the Raspberry Pi. Error Code: $EXIT_CODE."
  fi
else
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "[  \e[1;32mOK\e[0m  ] Installicious successfully customized the bash customizations for the Raspberry Pi."
  else
    echo -e "[ \e[1;31mFAIL\e[0m ] Installicious could not customize the bash customizations for the Raspberry Pi. Error Code: $EXIT_CODE."
  fi
fi

exit $EXIT_CODE