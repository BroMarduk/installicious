#!/bin/sh

# Get all IP Addresses
IP_INT=$(echo $(hostname -I))

if [ -z "$IP_INT" ]; then
  IP_EXT="No External Addresses"
else
  IP_EXT=`wget -q -O - %%MOTD_IP_URL%% | tail`
fi

echo $IP_EXT > /etc/motd.d/%%MOTD_NAME%%/results-ip