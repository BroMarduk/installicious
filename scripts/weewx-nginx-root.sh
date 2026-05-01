#!/bin/bash
# weewx-nginx-root.sh
# Point nginx's default site at the WeeWX report directory so that
# visiting http://<pi>/ shows the WeeWX page (or the loading page
# before weewx has generated reports) instead of "Welcome to nginx!".
#
# What this changes:
#   - /etc/nginx/sites-available/default  (replaced, with backup)
#   - nothing else — the default site stays enabled via its existing
#     symlink in /etc/nginx/sites-enabled/
#
# No SSL. Listens on port 80 for any hostname. Add SSL later with certbot.
# Run as root.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

SITE_AVAIL="/etc/nginx/sites-available/default"
SITE_ENABLED="/etc/nginx/sites-enabled/default"
WEEWX_WEB_DIR="/var/www/html/weewx"

# --- Sanity checks -------------------------------------------------------
command -v nginx >/dev/null || { echo "nginx is not installed."; exit 1; }

if [[ ! -d "$WEEWX_WEB_DIR" ]]; then
  echo "Expected $WEEWX_WEB_DIR to exist (the weewx tmpfs)."
  echo "Run weewx-site-ramdisk.sh first."
  exit 1
fi

# --- Back up the old site config ----------------------------------------
if [[ -f "$SITE_AVAIL" ]]; then
  BACKUP="${SITE_AVAIL}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$SITE_AVAIL" "$BACKUP"
  echo "Backed up existing site to $BACKUP"
fi

# --- Write the new default site -----------------------------------------
cat > "$SITE_AVAIL" <<'NGINX_EOF'
# Default site — serves WeeWX reports at /
#
# The document root is the WeeWX tmpfs, populated by:
#   1. weewx-site-ramdisk.sh     (drops a loading page into place at boot)
#   2. weewx itself               (regenerates reports every ~5 minutes)
#
# If you later add a domain + SSL (certbot), certbot will edit this file
# in place; the root/index/location blocks below are what it keys off of.

server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html/weewx;
    index index.html index.htm;

    # Catch-all hostname for now. Change to e.g. "weather.example.com"
    # before running certbot.
    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    # Weewx report images/HTML are static; let browsers cache briefly so
    # a reload during a regeneration doesn't hit a half-written file.
    location ~* \.(png|jpg|jpeg|gif|svg|ico|css|js)$ {
        expires 5m;
        add_header Cache-Control "public, max-age=300";
    }
}
NGINX_EOF

# --- Make sure it's enabled ---------------------------------------------
if [[ ! -L "$SITE_ENABLED" ]]; then
  ln -sf "$SITE_AVAIL" "$SITE_ENABLED"
  echo "Enabled default site symlink."
fi

# --- Test & reload -------------------------------------------------------
echo "Testing nginx config..."
if ! nginx -t; then
  echo "nginx config test FAILED. Restoring backup if present." >&2
  if [[ -n "${BACKUP:-}" && -f "$BACKUP" ]]; then
    cp -a "$BACKUP" "$SITE_AVAIL"
    nginx -t && echo "Restored backup." || echo "Backup also failed!" >&2
  fi
  exit 2
fi

systemctl reload nginx
echo
echo "Done. nginx is now serving $WEEWX_WEB_DIR at http://<pi>/"
echo
echo "Verify:"
echo "  curl -sI http://localhost/ | head -1            # expect 200 OK"
echo "  curl -s  http://localhost/ | head -5            # first lines of the page"
echo "  ls -l /var/www/html/weewx/index.html"