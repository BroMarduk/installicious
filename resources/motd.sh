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
    login="$(date -d $loginDate +"%a, %-d %b %Y, %-I:%M:%S %p") ($loginIP)"
    if [[ $loginStatus == still ]]; then
      login="$login [ONLINE]"
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

# Get SSH Information - handle Wheezy differently.
if [[ $numversion -ge 8 ]]; then
  ssh_failures=`journalctl -u ssh.service | grep "sshd" | awk /failure/ | wc -l`
  ssh_week=`journalctl -u ssh.service | grep "Accepted password" | awk /$user/ | wc -l`
else
  ssh_failures=`grep sshd /var/log/auth.log | awk /failure/ | wc -l`
  ssh_week=`grep "Accepted password" /var/log/auth.log | awk /$user/ | wc -l`
fi

# Get Login Counts
logins=`who -q`
logins_count=`echo $logins | cut -d"=" -f2`

# Get Uptime Information
upSeconds="$(/usr/bin/cut -d. -f1 /proc/uptime)"
secs=$((${upSeconds}%60))
mins=$((${upSeconds}/60%60))
hours=$((${upSeconds}/3600%24))
days=$((${upSeconds}/86400))

uptime=`printf "%d days, %02d hours %02d minutes %02d seconds" $days $hours $mins $secs`

# Get Load Averages
read one five fifteen rest < /proc/loadavg

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
  if [[ -z "$weather" ]]; then
    weatherDisplay="None"
  else
    if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-weather-date ]]; then
      read weatherDate < /etc/motd.d/%%MOTD_NAME%%/results-weather-date
      if [[ -z "$weatherDate" ]]; then
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

echo "$(tput setaf 2)
   .~~.   .~~.       `date +"%A, %-e %B %Y, %r"`
  '. \ ' ' / .'      Raspbian $version - $raspbian (`uname -rm`)$(tput setaf 1)
   .~ .~~~..~.
  : .~.'~'.~. :      _/_/_/                        _/      _/              _/
 ~ (   ) (   ) ~    _/    _/    _/_/_/  _/_/_/    _/_/    _/    _/_/    _/_/_/_/
( : '~'.~.'~' : )  _/    _/  _/    _/  _/    _/  _/  _/  _/  _/_/_/_/    _/
 ~ .~ (   ) ~. ~  _/    _/  _/    _/  _/    _/  _/    _/_/  _/          _/
  (  : '~' :  )  _/_/_/      _/_/_/  _/    _/  _/      _/    _/_/_/      _/_/
   '~ .~~~. ~'
       '~'       ${machine} [`hostname`] 

$(tput setaf 1)  Last Login    :$(tput setaf 2) $login
$(tput setaf 1)  SSH Logins    :$(tput setaf 2) Current: $logins_count | Failed: ${ssh_failures} | All '$user': $ssh_week
$(tput setaf 1)  Uptime        :$(tput setaf 2) $uptime
$(tput setaf 1)  Disk Space    :$(tput setaf 2) `df -h ~ | awk 'NR==2 { printf "Total: %sB, Used: %sB, Free: %sB",$2,$3,$4; }'`
$(tput setaf 1)  Memory        :$(tput setaf 2) `free -m | awk 'NR==2 { printf "Used: %sMB, Free: %sMB",$3,$4; }'` (`ps ax | wc -l | tr -d " "` Processes)
$(tput setaf 1)  Load Averages :$(tput setaf 2) $one @ 1 Minute | $five @ 5 Minutes | $fifteen @ 15 Minutes
$(tput setaf 1)  Temperature   :$(tput setaf 2) $temperatureOutput
$(tput setaf 1)  Internal IP   :$(tput setaf 2) $ipInternal
$(tput setaf 1)  External IP   :$(tput setaf 2) $ipExternal
$(tput setaf 1)  Weather 05255 :$(tput setaf 2) $weatherDisplay
$(tput sgr0)"
