#!/bin/sh

TODAY=`date +"%a, %-e %b %Y, %-I:%M %p"`
WEATHER=`curl -s "http://rss.accuweather.com/rss/liveweather_rss.asp?metric=2&locCode=%%MOTD_WEATHER_LOC_CODE%%" | sed -n '/Currently:/ s/.*: \(.*\): \([0-9]*\)\([CF]\).*/\2°\3, \1/p'`
echo $WEATHER > /etc/motd.d/%%MOTD_NAME%%/results-weather
echo $TODAY > /etc/motd.d/%%MOTD_NAME%%/results-weather-date