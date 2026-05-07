# features/feature-locale.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config.
# Sourced automatically when feature-locale contributes editable keys.
#
# This file defines _default_<KEY>() helpers that return the live system
# value for each editable key. menu_edit_config calls them when the
# static config (config/locale.config + menu-config.sh) leaves the value
# blank — purely so the user sees what's currently configured rather
# than an empty row. The displayed value is NOT persisted unless the
# user edits the row, so the "blank means preserve" semantics in
# config/locale.config stay intact.

_default_LOCALE_LANG() {
  [[ -f /etc/default/locale ]] || return 0
  grep -E '^LANG=' /etc/default/locale 2>/dev/null \
    | head -1 \
    | sed -E 's/^LANG="?//; s/"?$//'
}

_default_LOCALE_TIMEZONE() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl show --property=Timezone --value 2>/dev/null
  elif [[ -f /etc/timezone ]]; then
    head -1 /etc/timezone 2>/dev/null
  fi
}

_default_LOCALE_KEYBOARD_LAYOUT() {
  [[ -f /etc/default/keyboard ]] || return 0
  grep -E '^XKBLAYOUT=' /etc/default/keyboard 2>/dev/null \
    | head -1 \
    | sed -E 's/^XKBLAYOUT="?//; s/"?$//'
}

_default_LOCALE_KEYBOARD_MODEL() {
  [[ -f /etc/default/keyboard ]] || return 0
  grep -E '^XKBMODEL=' /etc/default/keyboard 2>/dev/null \
    | head -1 \
    | sed -E 's/^XKBMODEL="?//; s/"?$//'
}

_default_LOCALE_WIFI_COUNTRY() {
  # Legacy raspi-config layout: country=XX in wpa_supplicant.conf.
  local wpa="/etc/wpa_supplicant/wpa_supplicant.conf"
  if [[ -f $wpa ]]; then
    local v
    v=$(grep -E '^country=' "$wpa" 2>/dev/null | head -1 \
        | sed -E 's/^country=//; s/[[:space:]#].*//')
    if [[ -n $v ]]; then
      echo "$v"
      return 0
    fi
  fi
  # Newer NetworkManager / kernel regdomain via iw.
  if command -v iw >/dev/null 2>&1; then
    iw reg get 2>/dev/null | awk '/^country/ {gsub(":",""); print $2; exit}'
  fi
}
