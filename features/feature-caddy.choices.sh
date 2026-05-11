# features/feature-caddy.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config. Defines
# the CADDY_HTTP_POLICY radio so the user picks via a menu instead of
# typing the value. Sourced when feature-caddy contributes editable keys
# to the editor.
#
# Mirrors feature-webserver-ssl.choices.sh's WEBSERVER_SSL_HTTP_POLICY
# choices — the Caddy knob just plugs into Caddy's own auto-HTTPS
# pipeline instead of certbot.

_choices_CADDY_HTTP_POLICY() {
  printf 'redirect-all\tRedirect every HTTP request to HTTPS (default)\n'
  printf 'redirect-name\tRedirect only when Host matches the domain; LAN IP keeps HTTP\n'
  printf 'deny-http\tBlock all :80 traffic except Let'\''s Encrypt challenge\n'
}
