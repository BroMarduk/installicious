# features/feature-webserver.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config.
# Sourced when feature-webserver contributes editable keys.
#
# Provides _default_<KEY>() helpers that return live system values for
# WEBSERVER_* keys when the static config + menu-config.sh leave them
# blank. The displayed value is shown in the editor only — it is NOT
# persisted unless the user explicitly edits the row, preserving the
# "blank means use runtime default" semantics in config/webserver.config.

_default_WEBSERVER_SERVER_NAME() {
  # Fall back chain: hostname -f (FQDN) -> hostname (short) -> "localhost".
  local h
  if command -v hostname >/dev/null 2>&1; then
    h=$(hostname -f 2>/dev/null)
    [[ -z $h || $h == "(none)" ]] && h=$(hostname 2>/dev/null)
  fi
  [[ -z $h ]] && [[ -r /etc/hostname ]] && h=$(head -1 /etc/hostname 2>/dev/null)
  echo "${h:-localhost}"
}

_default_WEBSERVER_DOC_ROOT() {
  echo "/var/www/html"
}

_default_WEBSERVER_PORT() {
  echo "80"
}
