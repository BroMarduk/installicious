#!/bin/bash

# Get User
user=`whoami`

# Get Device
machine=`tr -d '\0' < /proc/device-tree/model`

# Get Version and Login Information - This method works for all verions of Raspian/Raspberry Pi OS
read version < /etc/debian_version
numversion=${version%%.*}

if [[ $numversion -ge 9 ]]; then
  read loginFrom loginIP loginDate loginStatus <<< $(last $user --time-format iso -2 | awk 'NR==2 { print $1,$3,$4,$5 }')
  if [[ $numversion -gt 12 ]]; then
    raspbian="Trixie"
  elif [[ $numversion -eq 12 ]]; then
    raspbian="Bookworm"
  elif [[ $numversion -eq 11 ]]; then
    raspbian="Bullseye"
  elif [[ $numversion -eq 10 ]]; then
    raspbian="Buster"
  else
    raspbian="Stretch"
  fi
  # TTY login
  if [[ $loginDate == - ]]; then
    loginDate=$loginIP
    loginIP=$loginFrom
  fi
  if [[ $loginDate == *T* ]]; then
    login="$(date -d $loginDate +"%-d %b %Y, %-I:%M %p") ($loginIP)"
    if [[ $loginStatus == still ]]; then
      login="$login [ON]"
    fi
  else
    # Not enough logins
    login="None"
  fi
else
  if [[ $numversion -eq 8 ]]; then
    raspbian="Jessie"
  else
    raspbian="Wheezy"
  fi
  read loginFrom loginIP loginDate <<< $(last $user -2 | awk 'NR==2 { print $1,$3,$4 ", "  $5 " " $6 " " $7 }')
  login="User '$loginFrom' on $loginDate ($loginIP)"
fi

# Get Uptime Information
upSeconds="$(/usr/bin/cut -d. -f1 /proc/uptime)"
secs=$(($upSeconds%60))c
mins=$(($upSeconds/60%60))
hours=$(($upSeconds/3600%24))
days=$(($upSeconds/86400))

uptime=`printf "%d days, %02d hours %02d minutes %02d seconds" $days $hours $mins $secs`

# Get Internal IP Information
ipInternal=$(hostname -I)

if [[ -z $ipInternal ]]; then
  ipInternal="None"
fi

# Get External IP Information
if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-ip ]]; then
  read ipExternal < /etc/motd.d/%%MOTD_NAME%%/results-ip
  if [[ -z $ipExternal ]]; then
    ipExternal = "None"
  fi
else
  ipExternal="None"
fi

# Get Weather Information
if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-weather ]]; then
  read weather < /etc/motd.d/%%MOTD_NAME%%/results-weather
  if [[ -z $weather ]]; then
    weatherDisplay="None"
  else
    if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-weather-date ]]; then
      read weatherDate < /etc/motd.d/%%MOTD_NAME%%/results-weather-date
      if [[ -z $weatherDate ]]; then
        weatherDisplay="$weather ($weatherDate)"
      else
        weatherDisplay=$weather
      fi
    else
      weatherDisplay=$weather
    fi
  fi
else
  weatherDisplay="None"
fi

# Get Temperature
cpuTemp0=$(cat /sys/class/thermal/thermal_zone0/temp)
cpuTemp1=$(($cpuTemp0/1000))
cpuTemp2=$(($cpuTemp0/100))
cpuTempM=$(($cpuTemp2 % $cpuTemp1))
cpuTemp="$cpuTemp1.$cpuTempM" 

if [[ -f /usr/bin/vcgencmd ]]; then
  gpuTemp="$(/usr/bin/vcgencmd measure_temp | grep -o '[0-9]*\.[0-9]*')"
elif [[ -f /opt/vc/bin/vcgencmd ]]; then
  gpuTemp="$(/opt/vc/bin/vcgencmd measure_temp | grep -o '[0-9]*\.[0-9]*')"
fi

if [[ -z gpuTemp ]]; then
  temperatureOutput="CPU: $cpuTemp °C"
else
  temperatureOutput="CPU: $cpuTemp °C | GPU: $gpuTemp °C"
fi

clear

echo "$(tput setaf 1)______            _   _      _
|  _  \          | \ | |    | |
| | | |__ _ _ __ |  \| | ___| |_
| | | / _\` | \`_ \| . \` |/ _ \ __|
| |/ / (_| | | | | |\  |  __/ |_
|___/ \__,_|_| |_\_| \_/\___|\__|
$(tput setaf 2)
`date +"%A, %-e %B %Y, %r"`
$(tput setaf 1)Raspbian $version - $raspbian (`uname -r`)
$machine [`hostname`]

Login  :$(tput setaf 2) $login
$(tput setaf 1)Uptime :$(tput setaf 2) $uptime
$(tput setaf 1)Disk   :$(tput setaf 2) `df -h ~ | awk 'NR==2 { printf "Total: %sB, Used: %sB, Free: %sB",$2,$3,$4; }'`
$(tput setaf 1)Memory :$(tput setaf 2) `free -m | awk 'NR==2 { printf "Used: %sMB, Free: %sMB",$3,$4; }'` (`ps ax | wc -l | tr -d " "` Processes)
$(tput setaf 1)Temp   :$(tput setaf 2) $temperatureOutput
$(tput setaf 1)IPs    :$(tput setaf 2) Int: $ipInternal Ext: $ipExternal
$(tput setaf 1)WX     :$(tput setaf 2) $weatherDisplay
$(tput sgr0)"
