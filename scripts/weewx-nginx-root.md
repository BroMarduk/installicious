# nginx → WeeWX (HTTP) — Setup Guide

Replace nginx's default "Welcome to nginx!" landing page with the WeeWX
reports directory, so hitting `http://<your-pi>/` goes straight to your
weather page (or the loading page, until WeeWX finishes its first report
cycle).

**HTTP only** — no TLS. If you want HTTPS, run this first to get the
server block shaped the way certbot expects, then run
`weewx-nginx-ssl.sh` (or run certbot directly).

---

## What this gives you

| Component                                     | Purpose                                                 |
|-----------------------------------------------|---------------------------------------------------------|
| `/etc/nginx/sites-available/default`          | Server block, `root` pointed at `/var/www/html/weewx`   |
| `/etc/nginx/sites-enabled/default`            | Symlink to the above — Debian nginx's standard pattern  |
| `/etc/nginx/sites-available/default.bak.…`    | Timestamped backup of whatever was there before         |
| Brief cache headers on static assets          | 5-minute `Cache-Control` on png/jpg/css/js so a reload during report regeneration doesn't catch a half-written file |
| `server_name _;` (catch-all)                  | Responds to any hostname — easy to replace with a real domain before running certbot |

### Request flow

```mermaid
flowchart LR
    U[browser] --> N[nginx :80<br/>default_server]
    N --> T{file exists?<br/>try_files}
    T -- index.html --> D[/var/www/html/weewx/index.html<br/>tmpfs]
    T -- asset --> A[.png / .css / .js<br/>5m Cache-Control]
    T -- neither --> F[404]
    D --> B[browser renders<br/>WeeWX report or loading page]
    A --> B
```

### Idempotence

The installer `weewx-nginx-root.sh` is safe to re-run. It:

- **Backs up** the current `/etc/nginx/sites-available/default` with a
  timestamp (`…bak.YYYYMMDD-HHMMSS`) on every run — no backup is ever
  overwritten
- **Overwrites** `sites-available/default` with the embedded server block
- **Ensures the symlink** `sites-enabled/default → sites-available/default`
  exists (idempotently)
- **Runs `nginx -t`** before reloading — if the test fails, it restores
  the most recent backup automatically and exits non-zero
- **Reloads** nginx (not restart — no dropped connections)

It does not touch `/etc/nginx/nginx.conf`, any other `sites-available/*`
files, or WeeWX itself.

---

## Prerequisites

| Thing                                | Notes                                                  |
|--------------------------------------|--------------------------------------------------------|
| nginx installed (`apt install nginx`) | Debian-flavoured nginx with the `sites-available`/`sites-enabled` layout |
| `/var/www/html/weewx` exists         | Created by `weewx-site-ramdisk.sh` (as a tmpfs); the installer refuses to proceed if missing |
| Port 80 free on the Pi               | If something else is listening (Apache, podman, etc.) nginx won't bind |

**Run order**:

1. `sudo bash install-ramdisk.logging.sh`
2. `sudo bash weewx-database-ramdisk.sh`
3. `sudo bash weewx-site-ramdisk.sh`  ← creates `/var/www/html/weewx`
4. **`sudo bash weewx-nginx-root.sh`**  ← this script
5. (optional) `sudo bash weewx-nginx-ssl.sh`
6. (optional) `sudo bash weewx-onedrive-backup.sh`

---

## How to run

```bash
sudo bash weewx-nginx-root.sh
```

What you'll see:

```
Backed up existing site to /etc/nginx/sites-available/default.bak.20260419-223045
Testing nginx config...
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

Done. nginx is now serving /var/www/html/weewx at http://<pi>/
```

If `nginx -t` fails, the installer restores the most recent backup and
exits with code 2 — your previous nginx state is preserved.

---

## What it does (detail)

1. **Sanity check**: confirms `nginx` is installed and
   `/var/www/html/weewx` exists (refuses to proceed if not — run
   `weewx-site-ramdisk.sh` first)
2. **Backs up** `/etc/nginx/sites-available/default` with a timestamped
   suffix so the history accumulates across re-runs
3. **Writes a new default site** with:
   - `listen 80 default_server;` + IPv6 equivalent
   - `root /var/www/html/weewx;`
   - `index index.html index.htm;`
   - `server_name _;` catch-all so any hostname (including raw IP)
     matches
   - `location / { try_files $uri $uri/ =404; }` — standard static-file
     serving
   - `location ~* \.(png|jpg|jpeg|gif|svg|ico|css|js)$` block adding
     `expires 5m;` + `Cache-Control: public, max-age=300;` so browsers
     briefly cache static assets — shields visitors from the
     half-written-file race during WeeWX report regeneration
4. **Creates the `sites-enabled/default` symlink** if it isn't there
5. **Runs `nginx -t`** before reloading; if the test fails, restores the
   backup and exits 2
6. **`systemctl reload nginx`** — picks up the new config without
   dropping in-flight connections

---

## What you can customize

Everything lives in `/etc/nginx/sites-available/default` — edit
post-install and `sudo nginx -t && sudo systemctl reload nginx` to apply.
**Re-running the installer overwrites your edits** (backing them up
first), so save customizations elsewhere if you plan to re-run.

| Thing                   | Where in the file                                 | Notes                                                   |
|-------------------------|---------------------------------------------------|---------------------------------------------------------|
| Document root           | `root /var/www/html/weewx;`                       | Must match WeeWX's `HTML_ROOT` in `weewx.conf`          |
| Hostname                | `server_name _;`                                  | Change to `weather.example.com` **before** running certbot |
| Listen port             | `listen 80 default_server;`                       | Change if something else owns :80 (and update firewall) |
| Cache duration          | `expires 5m;` in the assets `location`            | Bump to `1h`/`1d` if WeeWX report cadence is longer     |
| Access / error logs     | not set — uses nginx defaults (`/var/log/nginx/`) | Add `access_log` / `error_log` lines if you want per-site logs |
| gzip / brotli           | not set                                           | nginx's default `gzip on;` in `nginx.conf` already compresses HTML/CSS/JS |

If you want a durable set of changes, keep them in a separate file under
`sites-available/` (e.g. `sites-available/weewx`) and disable the default
via `rm /etc/nginx/sites-enabled/default`. Then this installer won't
touch your custom site.

---

## Differences by Raspberry Pi model / configuration

| Scenario                                          | Consideration                                                              |
|---------------------------------------------------|----------------------------------------------------------------------------|
| Exposing to the public internet                   | Set `server_name` to your real domain, then run `weewx-nginx-ssl.sh` or `sudo certbot --nginx` to add HTTPS. Also open port 80/443 on your router |
| LAN-only (most home weather stations)             | The default `server_name _;` is fine — visit `http://<pi-hostname>/` or `http://<pi-ip>/` |
| Pi behind Cloudflare / other reverse proxy        | Add `set_real_ip_from …;` and `real_ip_header CF-Connecting-IP;` in the server block so logs show real client IPs |
| Pi 3 / Zero 2 with very slow SD                   | Irrelevant — nginx serves from tmpfs now, SD speed only matters at boot    |
| IPv6 disabled                                     | The `listen [::]:80 default_server;` line may complain; either remove it or `sysctl net.ipv6.conf.all.disable_ipv6=0`  |
| Running another web app on the same Pi            | Leave this site as `default_server` and add a second `sites-available/<app>` with `server_name <app>.example.com;` |

---

## How to validate success

**Right after install:**

```bash
# 1. Config syntax is good
sudo nginx -t

# 2. The symlink is in place
ls -l /etc/nginx/sites-enabled/default

# 3. nginx is running
systemctl status nginx --no-pager | head

# 4. Serving the right root
curl -sI http://localhost/ | head -1       # expect HTTP/1.1 200 OK
curl -s  http://localhost/ | head -5       # first lines of your page

# 5. Asset caching header is being applied
curl -sI http://localhost/favicon.ico 2>/dev/null | grep -i cache-control
# (or use any .css/.png that exists; expect "Cache-Control: public, max-age=300")

# 6. The document root is what we expect
grep -E '^\s*root' /etc/nginx/sites-available/default
```

**From another machine on the same LAN:**

```bash
# Replace with your Pi's hostname or IP
curl -sI http://RPI3-TRIXIE-WEEWX.local/ | head -1
```

**End-to-end check** that WeeWX → tmpfs → nginx works:

```bash
# Drop a sentinel file into the tmpfs
echo "hello from $(date)" | sudo tee /var/www/html/weewx/test.txt
curl -s http://localhost/test.txt
sudo rm /var/www/html/weewx/test.txt
```

**Periodic** health check:

```bash
curl -sI http://localhost/ | grep -E 'HTTP|Content-Length'
systemctl is-active nginx
sudo tail -20 /var/log/nginx/error.log
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `nginx: [emerg] … directory not found /var/www/html/weewx` | Tmpfs isn't mounted | `mount \| grep weewx`; if empty, `sudo mount /var/www/html/weewx` or re-run `weewx-site-ramdisk.sh` |
| `curl http://localhost/` returns 403 | Directory is a tmpfs but empty (no `index.html`) | Run `weewx-site-ramdisk.sh`, or wait for WeeWX's first report cycle |
| `curl http://localhost/` returns "Welcome to nginx!" | The installer's new config didn't take effect, or something else is listening on :80 | `sudo nginx -T \| grep -A2 'server_name'` — verify the site block is loaded. Also check `sudo ss -ltnp \| grep :80` |
| `nginx -t` fails after re-run | Something got corrupted in the new file; installer should auto-rollback | `ls /etc/nginx/sites-available/default.bak.*` — manually restore the latest: `sudo cp default.bak.<ts> default && sudo nginx -t && sudo systemctl reload nginx` |
| 502/504 errors | You have a proxy_pass in there — this default config has none | Check for a stale `include` or a second enabled site overriding this one |
| Access logs show lots of 404s on `/setup` or `/.env` | Internet-exposed nginx, bot scanning | Normal for anything on the public net. Consider fail2ban or making the site LAN-only |
| Certbot's `--nginx` can't find the server block | `server_name _;` — certbot wants a real hostname | Edit the file, change `server_name _;` to your domain, `nginx -t && reload`, then re-run certbot |
| `ERR_CONNECTION_REFUSED` from a browser | Port 80 blocked at the firewall (Pi or router), or nginx not running | `sudo systemctl status nginx`; `sudo ufw status`; check router port-forward if remote |
| Mixed content / half-loaded page during regen | 5-min asset cache helps but a hard-reload can still catch a half-written file | Increase `expires` to `15m` if this is common, or switch WeeWX to atomic report writes if your skin supports it |

### Diagnostic bundle

```bash
nginx -v
sudo nginx -T | head -80
sudo nginx -t
systemctl status nginx --no-pager | head -20
ls -la /etc/nginx/sites-available/ /etc/nginx/sites-enabled/
ls -la /var/www/html/weewx/ | head
mount | grep weewx
sudo ss -ltnp | grep -E ':80|:443'
sudo tail -40 /var/log/nginx/error.log
```

---

## Uninstall / revert

### Option A — restore nginx's original default site

```bash
# Find the oldest backup (the one from before you ever ran this installer)
ls -lt /etc/nginx/sites-available/default.bak.* | tail -1
# Restore it
sudo cp /etc/nginx/sites-available/default.bak.<oldest-timestamp> \
        /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx
```

### Option B — disable the site entirely

```bash
sudo rm /etc/nginx/sites-enabled/default
sudo systemctl reload nginx
# Now port 80 returns a blank 404; nothing is served
```

### Option C — remove nginx completely

```bash
sudo apt remove --purge nginx nginx-common nginx-full
sudo rm -rf /etc/nginx /var/log/nginx
```

This doesn't touch WeeWX, the tmpfs, or the loading page — only nginx
and its config.

### Partial revert — keep the site, just drop our asset caching

```bash
sudo cp /etc/nginx/sites-available/default \
        /etc/nginx/sites-available/default.bak.$(date +%s)
# Then edit default and delete the second location block:
sudo nano /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx
```

### Clean up accumulated backups (optional)

Each re-run leaves a new `…bak.YYYYMMDD-HHMMSS` file. Tidy:

```bash
ls -lt /etc/nginx/sites-available/default.bak.*
# Keep the 3 most recent, delete the rest:
ls -t /etc/nginx/sites-available/default.bak.* | tail -n +4 | xargs -r sudo rm --
```

---

## Related scripts

- `weewx-site-ramdisk.sh` — prerequisite. Creates `/var/www/html/weewx`
  as a tmpfs and installs the loading page
- `weewx-nginx-ssl.sh` — adds TLS to the same site (edit the installer's
  embedded cert/domain before running, or run this one first then do
  `sudo certbot --nginx`)
- `weewx-database-ramdisk.sh` — moves the WeeWX SQLite DB to zram so the
  report regeneration doesn't thrash the SD card
- `weewx-onedrive-backup.sh` — off-site DB backups (nginx's HTML output
  is always regeneratable from the DB, so no need to back it up)