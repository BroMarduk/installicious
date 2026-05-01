#!/bin/bash

STATUS=0
EXIT_CODE=0

# Check to see if Whiptail is installed and uninstall it if it is.
if which whiptail >/dev/null; then
  sudo apt-get remove --yes whiptail
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    STATUS=-1
    EXIT_CODE=$RET_VAL
  fi
  STATUS=1
fi

echo $STATUS
exit $EXIT_CODE
