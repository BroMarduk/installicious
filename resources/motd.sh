#!/bin/bash

###############################################################################
# User
###############################################################################
if [[ -n "$SUDO_USER" ]]; then
  user="$SUDO_USER"
else
  user="$(whoami)"
fi

###############################################################################
# Device
###############################################################################
machine="$(tr -d '\0' < /proc/device-tree/model)"

###############################################################################
# OS Version
###############################################################################
read -r version < /etc/debian_version
numversion="${version%%.*}"

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
if (( numversion >= 13 )); then
  login="None"
  if command -v loginctl >/dev/null 2>&1; then
    session_id="$(loginctl list-sessions --no-legend 2>/dev/null \
                   | awk -v u="$user" '$3==u {print $1; exit}')"
    if [[ -n "$session_id" ]]; then
      remote="no"; rhost=""; loginDate=""
      while IFS='=' read -r k v; do
        case "$k" in
          Timestamp)  loginDate="$v" ;;
          Remote)     remote="$v"    ;;
          RemoteHost) rhost="$v"     ;;
        esac
      done < <(loginctl show-session "$session_id" \
                 -p Timestamp -p Remote -p RemoteHost 2>/dev/null)

      loginIP="Local"
      [[ "$remote" == "yes" ]] && loginIP="${rhost:-remote}"

      if [[ -n "$loginDate" ]]; then
        login="$(date -d "$loginDate" '+%a, %-d %b %Y, %-I:%M:%S %p') ($loginIP) [ONLINE]"
      fi
    fi
  fi
else
  # Bookworm (12): loginctl path above only fires on Trixie+ (>=13); fall back
  # to `last --time-format iso` here.
  read -r loginFrom loginIP loginDate loginStatus \
    <<< "$(last "$user" --time-format iso -2 | awk 'NR==2 { print $1,$3,$4,$5 }')"

  if [[ "$loginDate" == "-" ]]; then
    loginDate="$loginIP"
    loginIP="$loginFrom"
  fi

  [[ "$loginIP" == ":0" ]] && loginIP="Local"

  if [[ "$loginDate" == *T* ]]; then
    login="$(date -d "$loginDate" '+%a, %-d %b %Y, %-I:%M:%S %p') ($loginIP)"
    [[ "$loginStatus" == "still" ]] && login="$login [ONLINE]"
  else
    login="None"
  fi
fi

###############################################################################
# System Info
###############################################################################
bits="$(getconf LONG_BIT)"

###############################################################################
# SSH Statistics
###############################################################################
ssh_failures="$(journalctl -u ssh.service | grep sshd | awk '/failure/' | wc -l)"
ssh_week="$(journalctl -u ssh.service | grep 'Accepted password' | awk "/$user/" | wc -l)"

###############################################################################
# Login Count
###############################################################################
logins_count="$(who -q | tail -n1 | cut -d= -f2)"

###############################################################################
# Uptime
###############################################################################
read -r upSeconds _ < /proc/uptime
upSeconds="${upSeconds%.*}"

secs=$(( upSeconds % 60 ))
mins=$(( upSeconds / 60 % 60 ))
hours=$(( upSeconds / 3600 % 24 ))
days=$(( upSeconds / 86400 ))

uptime="$(printf '%d days, %02d hours %02d minutes %02d seconds' \
  "$days" "$hours" "$mins" "$secs")"

###############################################################################
# Updates
###############################################################################
updates=""

if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-updates ]]; then
  read -r updates < /etc/motd.d/%%MOTD_NAME%%/results-updates
fi

###############################################################################
# Load Average
###############################################################################
read -r one five fifteen _ < /proc/loadavg

###############################################################################
# IP Addresses
###############################################################################
ipInternal="$(hostname -I)"
[[ -z "$ipInternal" ]] && ipInternal="None"

ipExternal="None"
if [[ -f /etc/motd.d/%%MOTD_NAME%%/results-ip ]]; then
  read -r ipExternal < /etc/motd.d/%%MOTD_NAME%%/results-ip
  [[ -z "$ipExternal" ]] && ipExternal="None"
fi

###############################################################################
# Weather
###############################################################################
weatherDisplay="None"

WEATHER_FILE="/etc/motd.d/%%MOTD_NAME%%/results-weather"
WEATHER_DATE_FILE="/etc/motd.d/%%MOTD_NAME%%/results-weather-date"
MAX_AGE_SECONDS=$((3 * 60 * 60))

MAX_LEN=43

if [[ -f "$WEATHER_FILE" ]]; then
  read -r weather < "$WEATHER_FILE"

  if [[ -n "$weather" && -f "$WEATHER_DATE_FILE" ]]; then
    read -r weatherDate < "$WEATHER_DATE_FILE"

    weatherEpoch="$(date -d "$weatherDate" +%s 2>/dev/null || echo 0)"
    nowEpoch="$(date +%s)"

    if (( weatherEpoch > 0 && nowEpoch - weatherEpoch <= MAX_AGE_SECONDS )); then
      weatherDisplay="$weather"

      # ------------------------------------------------------------
      # Enforce max width (truncate BEFORE comma only)
      # ------------------------------------------------------------
      if [[ "$weatherDisplay" == *","* ]]; then
        weatherText="${weatherDisplay%%,*}"
        weatherSuffix=",${weatherDisplay#*,}"

        suffixLen=${#weatherSuffix}
        maxWeatherLen=$((MAX_LEN - suffixLen))

        if (( maxWeatherLen < 0 )); then
          # Should never happen, but fail safe
          weatherDisplay="${weatherSuffix#, }"
        elif (( ${#weatherText} > maxWeatherLen )); then
          trimLen=$((maxWeatherLen - 3))
          (( trimLen < 0 )) && trimLen=0
          weatherDisplay="${weatherText:0:trimLen}...${weatherSuffix}"
        fi
      else
        # No comma present — hard truncate as last resort
        weatherDisplay="${weatherDisplay:0:MAX_LEN}"
      fi
    else
      weatherDisplay="Weather Data Expired"
    fi
  fi
fi

###############################################################################
# Throttle status (replaces the Weather line when motd-weather isn't installed)
###############################################################################
# motd-weather installs /etc/cron.hourly/motd-current-weather; we use its
# presence as the "weather feature is installed" signal. When it's missing,
# we surface the Pi's throttle/under-voltage state instead — far more useful
# than a permanently-empty "None" weather row on a station Pi without the
# weather add-on.
WEATHER_CRON="/etc/cron.hourly/motd-current-weather"
throttle_status=""

if [[ ! -e "$WEATHER_CRON" ]]; then
  if command -v vcgencmd >/dev/null 2>&1; then
    throttle_raw="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)"
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
  weatherLineLabel="Throttled    "
  weatherLineValue="$throttle_status"
else
  weatherLineLabel="Weather %%MOTD_WEATHER_ZIP_CODE%%"
  weatherLineValue="$weatherDisplay"
fi

###############################################################################
# Temperature
###############################################################################
cpuTempRaw="$(< /sys/class/thermal/thermal_zone0/temp)"
cpuTemp="$(( cpuTempRaw / 1000 )).$(( (cpuTempRaw / 100) % 10 ))"

gpuTemp=""
pmicTemp=""

if [[ -x /usr/bin/vcgencmd ]]; then
  gpuTemp="$(/usr/bin/vcgencmd measure_temp | grep -o '[0-9]*\.[0-9]*')"
  pmicTemp="$(/usr/bin/vcgencmd measure_temp pmic | grep -o '[0-9]*\.[0-9]*')"
elif [[ -x /opt/vc/bin/vcgencmd ]]; then
  gpuTemp="$(/opt/vc/bin/vcgencmd measure_temp | grep -o '[0-9]*\.[0-9]*')"
  pmicTemp="$(/opt/vc/bin/vcgencmd measure_temp pmic | grep -o '[0-9]*\.[0-9]*')"
fi

if [[ -z "$gpuTemp" ]]; then
  temperatureOutput="CPU: $cpuTemp °C"
elif [[ -z "$pmicTemp" ]]; then
  temperatureOutput="CPU: $cpuTemp °C | GPU: $gpuTemp °C"
else
  temperatureOutput="CPU: $cpuTemp °C | GPU: $gpuTemp °C | PMIC: $pmicTemp °C"
fi

###############################################################################
# Display
###############################################################################
clear

echo "$(tput setaf 2)
   .~~.   .~~.       $(date '+%A, %-e %B %Y, %r')$(tput setaf 1) $updates$(tput setaf 2)
  '. \ ' ' / .'      $raspbian $bits-bit - RPi OS $version ($(uname -r | cut -d- -f1) Kernel $(uname -m))$(tput setaf 1)
   .~ .~~~..~.
  : .~.'~'.~. :      _/_/_/                        _/      _/              _/
 ~ (   ) (   ) ~    _/    _/    _/_/_/  _/_/_/    _/_/    _/    _/_/    _/_/_/_/
( : '~'.~.'~' : )  _/    _/  _/    _/  _/    _/  _/  _/  _/  _/_/_/_/    _/
 ~ .~ (   ) ~. ~  _/    _/  _/    _/  _/    _/  _/    _/_/  _/          _/
  (  : '~' :  )  _/_/_/      _/_/_/  _/    _/  _/      _/    _/_/_/      _/_/
   '~ .~~~. ~'
       '~'       ${machine} [$(hostname)]

$(tput setaf 1)  Last Login    :$(tput setaf 2) $login
$(tput setaf 1)  SSH Logins    :$(tput setaf 2) Current: $logins_count | Failed: $ssh_failures | All '$user': $ssh_week
$(tput setaf 1)  Uptime        :$(tput setaf 2) $uptime
$(tput setaf 1)  Disk Space    :$(tput setaf 2) $(df -h ~ | awk 'NR==2 { printf "Total: %sB, Used: %sB, Free: %sB",$2,$3,$4 }')
$(tput setaf 1)  Memory        :$(tput setaf 2) $(free -m | awk 'NR==2 { printf "Used: %sMB, Free: %sMB",$3,$4 }') ($(ps ax | wc -l | tr -d ' ') Processes)
$(tput setaf 1)  Load Averages :$(tput setaf 2) $one @ 1m | $five @ 5m | $fifteen @ 15m
$(tput setaf 1)  Temperature   :$(tput setaf 2) $temperatureOutput
$(tput setaf 1)  Internal IP   :$(tput setaf 2) $ipInternal
$(tput setaf 1)  External IP   :$(tput setaf 2) $ipExternal
$(tput setaf 1)  $weatherLineLabel :$(tput setaf 2) $weatherLineValue
$(tput sgr0)"

