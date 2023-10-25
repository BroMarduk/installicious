#!/bin/bash
## Check to see if Whiptail is installed and install it if not.

STATUS=0
EXIT_STATUS=0

if which whiptail >/dev/null; then
  :
else
  sudo apt-get install --yes whiptail
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    STATUS=-1
    EXIT_STATUS=$RET_VAL
  fi
  STATUS=1
fi

echo $STATUS
exit $EXIT_STATUS
