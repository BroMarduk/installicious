#!/bin/bash

STATUS=0
EXIT_CODE=0

# Check to see if Git is installed and uninstall it if it is.
if which git >/dev/null; then
  sudo apt-get --yes --purge autoremove git
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    STATUS=-1
    EXIT_CODE=$RET_VAL
  else
    STATUS=1
  fi
fi

echo $STATUS
exit $EXIT_CODE
