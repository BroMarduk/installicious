###############################################################################
# Last Login (large/full format)
#
# Renders into $login. Works on Debian/Pi OS Jessie through Trixie+.
#   numversion >= 13  -> systemd-logind (last is no longer installed by default)
#   numversion >=  9  -> last with --time-format iso
#   numversion <   9  -> legacy last parsing
#
# Output examples:
#   "Sat, 18 Apr 2026, 10:42:13 AM (192.168.1.10) [ONLINE]"
#   "Sat, 18 Apr 2026, 10:42:13 AM (Local)"
#   "User 'pi' on Apr 18 2026, 10:42 AM (Local)"
#   "None"
###############################################################################

if (( numversion >= 13 )); then
  # Trixie+: `last` no longer ships by default; use systemd-logind.
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
        login="$(LC_TIME=C date -d "$loginDate" '+%a, %-d %b %Y, %-I:%M:%S %p') ($loginIP) [ONLINE]"
      fi
    fi
  fi

elif (( numversion >= 9 )); then
  read -r loginFrom loginIP loginDate loginStatus \
    <<< "$(last "$user" --time-format iso -2 | awk 'NR==2 { print $1,$3,$4,$5 }')"

  if [[ "$loginDate" == "-" ]]; then
    loginDate="$loginIP"
    loginIP="$loginFrom"
  fi

  [[ "$loginIP" == ":0" ]] && loginIP="Local"

  if [[ "$loginDate" == *T* ]]; then
    login="$(LC_TIME=C date -d "$loginDate" '+%a, %-d %b %Y, %-I:%M:%S %p') ($loginIP)"
    [[ "$loginStatus" == "still" ]] && login="$login [ONLINE]"
  else
    login="None"
  fi

else
  read -r loginFrom loginIP loginDate \
    <<< "$(last "$user" -2 | awk 'NR==2 { print $1,$3,$4 ", " $5 " " $6 " " $7 }')"

  [[ "$loginIP" == ":0" ]] && loginIP="Local"
  login="User '$loginFrom' on $loginDate ($loginIP)"
fi