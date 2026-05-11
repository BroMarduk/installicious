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

_choices_WEBSERVER_SSL_HTTP_POLICY() {
  printf 'redirect-all\tRedirect every HTTP request to HTTPS (default)\n'
  printf 'redirect-name\tRedirect only when Host matches the domain; LAN IP keeps HTTP\n'
  printf 'deny-http\tBlock all :80 traffic except Let'\''s Encrypt challenge\n'
}
