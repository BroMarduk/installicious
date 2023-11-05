#!/bin/bash

message_log() {
  REBOOT=$1
  OLDSTYLE=$2
  MODULE="$3"
  LEVEL="$4"
  LOG_FILE="$5"
  MESSAGE_LOG="$6"
  MESSAGE_SCREEN="$7"

  if [[ -z $MESSAGE_SCREEN ]]; then
    MESSAGE_SCREEN=$MESSAGE_LOG
  fi
  
  if [[ $OLDSTYLE -eq 0]]; then
    case ${LEVEL^^} in
      INFO)
        echo -e "[ \e[0;36mINFO\e[0m ] $MESSAGE_SCREEN"
        ;;
      OK)
        echo -e "[  \e[0;32mOK\e[0m  ] $MESSAGE_SCREEN"
        ;;
      WARN)
        echo -e "[ \e[0;33mWARN\e[0m ] $MESSAGE_SCREEN"
        ;;
      FAIL)
        echo -e "[ \e[0;31mFAIL\e[0m ] $MESSAGE_SCREEN"
        ;;
      *)
        echo -e "[ \e[0;35mMISC\e[0m ] $MESSAGE_SCREEN"
        ;;
    esac
  else
    case ${LEVEL^^} in
        INFO)
        echo -e "[\e[0;36minfo\e[0m] $MESSAGE_SCREEN"
        ;;
      OK)
        echo -e "[ \e[0;32mok\e[0m ] $MESSAGE_SCREEN"
        ;;
      WARN)
        echo -e "[\e[0;33mwarn\e[0m] $MESSAGE_SCREEN"
        ;;
      FAIL)
        echo -e "[\e[0;31mfail\e[0m] $MESSAGE_SCREEN"
        ;;
      *)
        echo -e "[\e[0;35mmisc\e[0m] $MESSAGE_SCREEN"
        ;;
  fi
  
  echo  "$(date '+%Y-%m-%d %T.%5N') -  ${LEVEL^^} - [$MODULE] $MESSAGE_LOG" >> $LOG_FILE
}
