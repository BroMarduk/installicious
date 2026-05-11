# Web server HTTP / HTTPS policy matrix

What actually happens for every combination of backend × policy × URL.
Examples use `WEBSERVER_SERVER_NAME=weather2.begallie.com` and
`192.168.2.139` as the Pi's LAN IP. Substitute your own values.

The three policies (`redirect-all`, `redirect-name`, `deny-http`) live
on two separate config knobs:

  - `WEBSERVER_SSL_HTTP_POLICY` — nginx / apache / lighttpd (via
    `feature-webserver-ssl`, using certbot for cert issuance).
  - `CADDY_HTTP_POLICY` — Caddy (via `feature-caddy`, using Caddy's
    built-in ACME client; the cert path is entirely Caddy-internal).

The two knobs accept the same three values and behave the same way
across backends with one footnote noted per cell. Each policy also
keeps `/.well-known/acme-challenge/` reachable on `:80` so HTTP-01
renewals don't break.

---

## `redirect-all`

Every HTTP request gets bounced to HTTPS, regardless of Host.

| URL | nginx | Caddy |
|---|---|---|
| `http://192.168.2.139` | `:80 default_server` → 301 to `https://192.168.2.139` → `:443 default_server` presents LE cert (CN=weather2.begallie.com) → **browser shows cert name-mismatch warning** → click through → page loads | Same redirect to `https://192.168.2.139` → `:443` catch-all presents self-signed cert (CN=weather2.begallie.com) → **browser shows self-signed + name-mismatch warning** → click through → page loads |
| `https://192.168.2.139` | `:443 default_server` (LE cert) → name-mismatch warning → page loads | `:443` catch-all (self-signed) → self-signed + name-mismatch warning → page loads |
| `http://weather2.begallie.com` | `:80 server_name=weather2…` → 301 to HTTPS → `:443` named server → **clean load, padlock** | Caddy auto-redirect for the named site → `:443` named site (LE cert) → **clean load, padlock** |
| `https://weather2.begallie.com` | `:443` named server (LE cert matches) → **clean load** | `:443` named site → **clean load** |

---

## `redirect-name`

Only requests whose Host is the canonical domain get redirected.
Other hosts on `:80` keep plain HTTP.

| URL | nginx | Caddy |
|---|---|---|
| `http://192.168.2.139` | `:80 default_server` → **serves plain HTTP** (no redirect) → under-construction page loads with no warning | Explicit `http:// { @canonical host weather2.begallie.com; … }` block — non-canonical hosts fall through to `file_server` → **serves plain HTTP** → page loads with no warning |
| `https://192.168.2.139` | `:443 default_server` (LE cert) → name-mismatch warning → page loads | `:443` catch-all (self-signed) → self-signed + name-mismatch warning → page loads |
| `http://weather2.begallie.com` | `:80` named → 301 to HTTPS → `:443` named → clean load | `@canonical` matcher hits → 301 to HTTPS → `:443` named → clean load |
| `https://weather2.begallie.com` | `:443` named → clean load | `:443` named → clean load |

> **Caddy implementation note:** without the explicit `http:// { @canonical … }`
> block, Caddy's auto-HTTPS would silently overlay a `:80→:443` redirect
> server that catches every Host — turning `redirect-name` into the same
> behavior as `redirect-all`. The block is what enforces the policy.

---

## `deny-http`

`:80` returns nothing useful for any host, except the Let's Encrypt
challenge path (so renewals still work).

| URL | nginx | Caddy |
|---|---|---|
| `http://192.168.2.139` | `:80 default_server` → 444 (no response). Browser shows "site can't be reached" | `http://` catch-all → 444 with `{ close }` → connection drops. Same "site can't be reached" UX |
| `https://192.168.2.139` | `:443 default_server` (LE cert) → name-mismatch warning → page loads | `:443` catch-all (self-signed) → self-signed + name-mismatch warning → page loads |
| `http://weather2.begallie.com` | `:80` named → **still redirects to HTTPS** (the canonical-domain redirect is preserved even in `deny-http` — nginx treats deny-http as "deny non-canonical HTTP") → clean load | Named site is written as `https://weather2.begallie.com { … }` so it doesn't claim `:80`. The `http://` catch-all wins and **also returns 444 for the canonical host** — Caddy treats deny-http as "deny ALL HTTP" |
| `https://weather2.begallie.com` | `:443` named → clean load | `:443` named → clean load |

> **Backend-asymmetric behavior on the canonical-host HTTP row:** nginx
> still redirects `http://weather2.begallie.com → https://...`; Caddy
> denies it outright. If you need the same behavior on both, the choice
> is which way to align — either teach Caddy to keep the canonical
> redirect, or teach nginx to also deny the canonical host. Currently
> they're documented as different.

---

## Common configuration

All four backends share these `WEBSERVER_*` knobs (set via the installicious
config editor):

| Knob | Used by | Notes |
|---|---|---|
| `WEBSERVER_DOC_ROOT` | all | filesystem root the named site serves from (default `/var/www/html`). |
| `WEBSERVER_SERVER_NAME` | all | canonical FQDN. Must resolve to a reachable IP for ACME to issue a real cert. |
| `WEBSERVER_PORT` | nginx / apache / lighttpd | non-443 HTTPS port; ignored by Caddy (which always uses `:80` + `:443`). |
| `WEBSERVER_SSL_EMAIL` | all (optional for Caddy) | Let's Encrypt registration address. Optional for Caddy → anonymous registration (no renewal reminders) if blank. |
| `WEBSERVER_SSL_HTTP_POLICY` | nginx / apache / lighttpd | the three values described above. |
| `WEBSERVER_SSL_METHOD` | nginx / apache / lighttpd | `http` (HTTP-01 via webroot) or `dns-cloudflare` (DNS-01). Ignored by Caddy. |
| `WEBSERVER_SSL_CF_TOKEN` | nginx / apache / lighttpd | only for `dns-cloudflare`. Token from <https://dash.cloudflare.com/profile/api-tokens> with **Zone → DNS → Edit** scope. |
| `CADDY_HTTP_POLICY` | Caddy | same three values as `WEBSERVER_SSL_HTTP_POLICY`. |

Caddy maintains a self-signed fallback cert at
`/etc/installicious/state/caddy-fallback.crt|key` (CN matches
`WEBSERVER_SERVER_NAME`) — that's what the `:443` catch-all presents to
unmatched-SNI connections.
