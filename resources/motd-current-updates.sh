#!/bin/sh

LOCK_FILE="/run/motd-updates-count.lock"
OUTPUT_FILE="/etc/motd.d/%%MOTD_NAME%%/results-updates"

(
  flock -n 9 || exit 0

  UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
  UPDATES=$(echo "$UPDATES" | tr -d ' ')

  case "$UPDATES" in
    ""|*[!0-9]*|0)
      UPDATE_TEXT=""
      ;;
    1)
      UPDATE_TEXT="- 1 Update"
      ;;
    *)
      UPDATE_TEXT="- $UPDATES Updates"
      ;;
  esac

  printf '%s\n' "$UPDATE_TEXT" > "$OUTPUT_FILE"
) 9>"$LOCK_FILE"