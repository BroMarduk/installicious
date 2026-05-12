#!/bin/bash

###############################################################################
# User
###############################################################################

if [ -n "$SUDO_USER" ]; then
    # If run with sudo, use the original user's name
    user="$SUDO_USER"
else
    # Otherwise, use the current user's name
    user="$(whoami)"
fi

###############################################################################
# Device
###############################################################################
machine=$(tr -d '\0' < /proc/device-tree/model)

###############################################################################
# OS Version
###############################################################################
read version < /etc/debian_version
numversion=${version%%.*}

case "$numversion" in
  15) raspbian="Duke" ;;
  14) raspbian="Forky" ;;
  13) raspbian="Trixie" ;;
  12) raspbian="Bookworm" ;;
  11) raspbian="Bullseye" ;;
  10) raspbian="Buster" ;;
   9) raspbian="Stretch" ;;
   8) raspbian="Jessie" ;;
   7) raspbian="Wheezy" ;;
   *) raspbian="Unknown" ;;
esac

###############################################################################
# Last Login
###############################################################################
read loginFrom loginIP loginDate loginStatus <<< $(last $user --time-format iso -2 | awk 'NR==2 { print $1,$3,$4,$5 }')

# TTY login adjustments
if [[ $loginDate == "-" ]]; then
  loginDate=$loginIP
  loginIP=$loginFrom
fi

# Local login check
if [[ $loginIP == ":0" ]]; then
  loginIP="Local"
fi

# Format login date and check online status
if [[ $loginDate == *T* ]]; then
  login=$(date -d "$loginDate" +"%-d %b %Y, %-I:%M %p")" ($loginIP)"
  if [[ $loginStatus == still ]]; then
    login="$login [ON]"
  fi
else
  # Not enough logins
  login="None"
fi

###############################################################################
# System Info
###############################################################################
bits=$(getconf LONG_BIT)

###############################################################################
# Uptime
###############################################################################
upSeconds=$(/usr/bin/cut -d. -f1 /proc/uptime)
secs=$(($upSeconds%60))
mins=$(($upSeconds/60%60))
hours=$(($upSeconds/3600%24))
days=$(($upSeconds/86400))

uptime=$(printf "%d days, %02d hours %02d minutes %02d seconds" $days $hours $mins $secs)

###############################################################################
# Updates
###############################################################################
# results-updates is written by /etc/cron.hourly/motd-current-updates as
# either empty (when zero / error) or "- N Update(s)". The small banner is
# tight on horizontal space so we extract just the number and render "- (N)".
updates=""

if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-updates ]]; then
  read -r updates_raw < /etc/motd.d/%%MOTD_NAME%%/results-updates
  if [[ $updates_raw =~ ([0-9]+) ]]; then
    updates="- (${BASH_REMATCH[1]})"
  fi
fi

###############################################################################
# IP Addresses
###############################################################################
ipInternal=$(hostname -I)

if [[ -z $ipInternal ]]; then
  ipInternal="None"
fi

if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-ip ]]; then
  read ipExternal < /etc/motd.d/%%MOTD_NAME%%/results-ip
  if [[ -z $ipExternal ]]; then
    ipExternal="None"
  fi
else
  ipExternal="None"
fi

###############################################################################
# Weather
###############################################################################

if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-weather ]]; then
  read weather < /etc/motd.d/%%MOTD_NAME%%/results-weather
  if [[ -z "$weather" ]]; then
    weatherDisplay="None"
  else
    if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-weather-date ]]; then
      read weatherDate < /etc/motd.d/%%MOTD_NAME%%/results-weather-date
      if [[ -z "$weatherDate" ]]; then
        weatherDisplay="$weather"
      else
        formattedDate=${weatherDate//,}
        shortWeatherDate=$(date -d "$formattedDate" +"%m/%d %I:%M %p")
        weatherDisplay="$weather ($shortWeatherDate)"
      fi
    else
      weatherDisplay="$weather"
    fi
  fi
else
  weatherDisplay="None"
fi

###############################################################################
# Throttle status (replaces the WX line when motd-weather isn't installed)
###############################################################################
# Same signal-source as motd.sh: motd-weather drops the hourly cron; absence
# of the cron file means the weather add-on is uninstalled, so show throttle
# state in its place.
WEATHER_CRON="/etc/cron.hourly/motd-current-weather"
throttle_status=""

if [[ ! -e "$WEATHER_CRON" ]]; then
  if command -v vcgencmd >/dev/null 2>&1; then
    throttle_raw=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [[ "$throttle_raw" == "0x0" ]]; then
      throttle_status="OK"
    else
      throttle_status="${throttle_raw:-?} - Check Power"
    fi
  else
    throttle_status="Unavailable"
  fi
fi

if [[ -n "$throttle_status" ]]; then
  weatherLineLabel="Throt "
  weatherLineValue="$throttle_status"
else
  weatherLineLabel="WX    "
  weatherLineValue="$weatherDisplay"
fi

###############################################################################
# Temperature
###############################################################################
cpuTemp0=$(cat /sys/class/thermal/thermal_zone0/temp)
cpuTemp1=$(($cpuTemp0/1000))
cpuTemp2=$(($cpuTemp0/100))
cpuTempM=$(($cpuTemp2 % $cpuTemp1))
cpuTemp="$cpuTemp1.$cpuTempM"

if [[ -f /usr/bin/vcgencmd ]]; then
  gpuTemp=$(/usr/bin/vcgencmd measure_temp | grep -o '[0-9]*\.[0-9]*')
  pmicTemp=$(/usr/bin/vcgencmd measure_temp pmic | grep -o '[0-9]*\.[0-9]*') # Only works on Pi 4 or above
elif [[ -f /opt/vc/bin/vcgencmd ]]; then
  gpuTemp=$(/opt/vc/bin/vcgencmd measure_temp pmic | grep -o '[0-9]*\.[0-9]*')
  pmicTemp=$(/opt/vc/bin/vcgencmd measure_temp pmic | grep -o '[0-9]*\.[0-9]*') # Only works on Pi 4 or above
fi

if [[ -z $gpuTemp ]]; then
  temperatureOutput="CPU: $cpuTemp °C"
else
  if [[ -z $pmicTemp ]]; then
    temperatureOutput="CPU: $cpuTemp °C | GPU: $gpuTemp °C"
  else
    temperatureOutput="CPU: $cpuTemp °C | GPU: $gpuTemp °C | PMIC: $pmicTemp °C"
  fi
fi

###############################################################################
# Display
###############################################################################
clear

echo "$(tput setaf 1)______            _   _      _
|  _  \          | \ | |    | |
| | | |__ _ _ __ |  \| | ___| |_
| | | / _\` | \`_ \| . \` |/ _ \ __|
| |/ / (_| | | | | |\  |  __/ |_
|___/ \__,_|_| |_\_| \_/\___|\__|
$(tput setaf 2)
$(date +"%A, %-e %B %Y, %r")$(tput setaf 1)${updates:+ $updates}$(tput setaf 2)
$(tput setaf 1)$raspbian $bits - Raspbian $version ($(uname -r | cut -d'-' -f1) Kernel)
$machine [$(hostname)]

Login  :$(tput setaf 2) $login
$(tput setaf 1)Uptime :$(tput setaf 2) $uptime
$(tput setaf 1)Disk   :$(tput setaf 2) $(df -h ~ | awk 'NR==2 { printf "Total: %sB, Used: %sB, Free: %sB",$2,$3,$4; }')
$(tput setaf 1)Memory :$(tput setaf 2) $(free -m | awk 'NR==2 { printf "Used: %sMB, Free: %sMB",$3,$4; }') ($(ps ax | wc -l | tr -d " ") Processes)
$(tput setaf 1)Temp   :$(tput setaf 2) $temperatureOutput
$(tput setaf 1)IPs    :$(tput setaf 2) Int: $ipInternal Ext: $ipExternal
$(tput setaf 1)$weatherLineLabel :$(tput setaf 2) $weatherLineValue
$(tput sgr0)"
