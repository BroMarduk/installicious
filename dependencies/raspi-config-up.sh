#!/bin/bash

STATUS=0
EXIT_CODE=0

# Check to see if Raspi-Config is installed and install it if not.
if which raspi-config >/dev/null; then
  :
else
  sudo apt-get install --yes raspi-config
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    STATUS=-1
    EXIT_CODE=$RET_VAL
  fi
  STATUS=1
fi

echo $STATUS
exit $EXIT_CODE

