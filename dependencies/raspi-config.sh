#!/bin/bash
## Check to see if Raspi-Config is installed and install it if not.

STATUS=0
EXIT_STATUS=0

if which raspi-config >/dev/null; then
  :
else
  sudo apt-get install --yes raspi-config
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    STATUS=-1
    EXIT_STATUS=$RET_VAL
  fi
  STATUS=1
fi

echo $STATUS
exit $EXIT_STATUS

