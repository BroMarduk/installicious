# features/feature-webserver-ssl.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config. Defines
# the WEBSERVER_SSL_METHOD radio so the user picks via menu instead of
# typing the value. Sourced when feature-webserver-ssl contributes
# editable keys to the editor.

_choices_WEBSERVER_SSL_METHOD() {
  printf 'http\tHTTP-01 (default; needs port 80 reachable)\n'
  printf 'dns-cloudflare\tDNS-01 via Cloudflare API (proxy can stay on)\n'
}
