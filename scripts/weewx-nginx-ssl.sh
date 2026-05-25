#!/bin/bash
# weewx-nginx-ssl.sh
# Obtain a Let's Encrypt certificate for weather.begallie.com, wire nginx
# up for HTTPS with automatic HTTP->HTTPS redirect, and make sure the
# auto-renewal timer is in place.
#
# Prerequisites (you MUST have these already):
#   1. A DNS A (and optionally AAAA) record for weather.begallie.com
#      pointing to this Pi's public IP.
#   2. Your router forwarding TCP ports 80 AND 443 to this Pi.
#      (Port 80 is required for Let's Encrypt's HTTP-01 challenge, both
#       for the initial issuance and for every renewal.)
#   3. weewx-nginx-root.sh already run, so nginx serves the weewx
#      directory at /.
#
# Run as root.
set -euo pipefail

# --- Configure here ------------------------------------------------------
DOMAIN="weather.begallie.com"
EMAIL="dan_begallie@hotmail.com"
SITE_AVAIL="/etc/nginx/sites-available/default"
# -------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# --- 1. Install certbot + nginx plugin if missing ------------------------
if ! command -v certbot >/dev/null; then
  echo "Installing certbot and the nginx plugin..."
  apt-get update
  apt-get install -y certbot python3-certbot-nginx
else
  echo "certbot already installed: $(certbot --version 2>&1)"
fi

# --- 2. Pre-flight checks ------------------------------------------------
echo
echo "Pre-flight checks for $DOMAIN ..."

# DNS resolution
if ! getent hosts "$DOMAIN" >/dev/null; then
  echo "WARNING: $DOMAIN does not resolve from this machine."
  echo "         Make sure your DNS A record is live before continuing."
  read -rp "Continue anyway? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
else
  RESOLVED=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)
  echo "  DNS:        $DOMAIN -> $RESOLVED"
fi

# Public IP (best-effort)
PUBIP=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
if [[ -n "$PUBIP" ]]; then
  echo "  Public IP:  $PUBIP"
  if [[ -n "${RESOLVED:-}" && "$RESOLVED" != "$PUBIP" ]]; then
    echo "  NOTE: DNS does not match your detected public IP. If you use"
    echo "        a dynamic DNS service or CDN that's fine; otherwise"
    echo "        Let's Encrypt won't be able to reach this server."
  fi
fi

# Local nginx is up and serving on port 80
if ! curl -sf -o /dev/null http://localhost/; then
  echo "ERROR: http://localhost/ is not serving successfully."
  echo "       Fix nginx before running this script."
  exit 1
fi
echo "  Local nginx: OK on port 80"

# --- 3. Point nginx server_name at the real domain -----------------------
# If the file still has the placeholder "server_name _;", replace it so
# certbot --nginx can find the right server block.
if grep -qE '^\s*server_name\s+_;\s*$' "$SITE_AVAIL"; then
  cp -a "$SITE_AVAIL" "${SITE_AVAIL}.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i -E "s/^(\s*)server_name\s+_;/\1server_name $DOMAIN;/" "$SITE_AVAIL"
  echo "Updated server_name to $DOMAIN in $SITE_AVAIL"
elif grep -qE "^\s*server_name\s+$DOMAIN;" "$SITE_AVAIL"; then
  echo "server_name already set to $DOMAIN."
else
  echo "NOTE: server_name in $SITE_AVAIL doesn't match the expected pattern."
  echo "      Current line:"
  grep -nE '^\s*server_name\s' "$SITE_AVAIL" || true
  echo "      certbot will try to detect the right block anyway."
fi

nginx -t
systemctl reload nginx

# --- 4. Obtain the certificate and configure HTTPS -----------------------
# --nginx   : use the nginx authenticator + installer plugin (no webroot
#             writes, so it plays nicely with the tmpfs document root)
# --redirect: insert a 301 redirect from http -> https
# --hsts    : add Strict-Transport-Security header (6-month default)
echo
echo "Running certbot to obtain + install the certificate..."
certbot --nginx \
  -d "$DOMAIN" \
  -m "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  --non-interactive \
  --redirect \
  --hsts \
  --keep-until-expiring

# --- 5. Verify auto-renewal ---------------------------------------------
# On Debian/Ubuntu, installing certbot also installs a systemd timer.
echo
if systemctl list-unit-files 'certbot*.timer' --no-legend | grep -q certbot; then
  systemctl enable --now certbot.timer 2>/dev/null || true
  systemctl status certbot.timer --no-pager -l | head -10
else
  echo "No certbot.timer found; check /etc/cron.d/certbot instead:"
  ls -l /etc/cron.d/certbot 2>/dev/null || echo "  (no cron entry either — investigate)"
fi

# Dry-run a renewal to prove the whole chain (nginx plugin + redirect +
# renewal hook) works end-to-end. This hits Let's Encrypt's staging
# endpoint — no rate limit impact on real certs.
echo
echo "Testing renewal (dry run)..."
certbot renew --dry-run

# --- 6. Final summary ---------------------------------------------------
cat <<DONE

SSL setup complete for https://$DOMAIN

Verify from your browser:
  https://$DOMAIN/              (should show the weewx page, valid padlock)
  http://$DOMAIN/               (should 301-redirect to https)

From the command line:
  curl -sI http://$DOMAIN/  | head -1     # expect: HTTP/1.1 301 Moved Permanently
  curl -sI https://$DOMAIN/ | head -1     # expect: HTTP/2 200

Certificate status:
  sudo certbot certificates

Auto-renewal (happens automatically; runs twice a day, only renews
when <30 days remain):
  systemctl list-timers certbot.timer
  sudo certbot renew --dry-run

If you ever need to re-issue, force, or revoke:
  sudo certbot --help
DONE