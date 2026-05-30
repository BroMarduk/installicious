# acme.sh Switch — Design (drop certbot + python-cloudflare)

**Date:** 2026-05-29
**Branch:** `ai-refactor`
**Status:** Approved (brainstorming complete; awaiting plan-writing)

## Goal

Replace `feature-webserver-ssl`'s `certbot + python3-certbot-dns-cloudflare`
chain with `acme.sh`, dropping the `python-cloudflare` (apt: `python3-cloudflare`)
dependency entirely. Extract the cert lifecycle into a shared `lib/cert.sh`
so future cert-needing features can reuse the same install / issue / renew
/ uninstall / verify primitives.

Also adds:
- **Multi-domain certs** (comma-delimited `WEBSERVER_SERVER_NAME`) across
  all four backends: nginx, apache, lighttpd, and Caddy. The first name in
  the list is the primary (cert path is keyed on it); the rest become SANs.
- **Wildcard certs** (`*.example.com`) for the three acme.sh-managed
  backends (nginx, apache, lighttpd). Requires
  `WEBSERVER_SSL_METHOD=dns-cloudflare` because Let's Encrypt only issues
  wildcards via DNS-01.

## Why

The current implementation works, but pulls in `python3-cloudflare` (the
older community Cloudflare client) via `python3-certbot-dns-cloudflare`'s
dep tree. That library emits a cosmetic `PendingDeprecationWarning` during
every certbot invocation, and the installer's only remediation is a sed
filter in `_obtain_cert` that strips the warning block from the install
log. The strategic fix — getting upstream certbot to migrate to the new
official `cloudflare-python` SDK — isn't on the project's schedule.

acme.sh talks to the Cloudflare API directly via `curl` / `wget` in shell,
so the entire Python Cloudflare-library chain disappears. acme.sh also
handles the renewal lifecycle natively (via either its own cron or, in
our case, a systemd timer), removing the dependency on `certbot.timer`.

## Non-goals

- **Migration of existing certbot installs.** The user confirmed there
  are no in-the-wild installs running the old code path that need
  preserving. New installs go to acme.sh; no auto-migration logic.
- **Wildcard certs on the Caddy backend.** Requires Caddy 2.7+'s
  `caddy add-package` mechanism and the `caddy-dns/cloudflare` plugin,
  plus runtime `CF_API_TOKEN` injection via systemd `Environment=`.
  Substantial separate work — deferred to a future feature-caddy update.
  Multi-domain (non-wildcard) on Caddy IS in scope here.
- **Multi-CA support.** acme.sh supports ZeroSSL, BuyPass, Google Trust
  Services, etc. We stay on Let's Encrypt (acme.sh's current default).
- **Real-network testing.** No live Let's Encrypt issuance in the test
  suite. Stubbed external commands; live verification stays the user's
  smoke test on a real Pi.

## File layout

### New files

```
lib/cert.sh                                          shared cert lifecycle
resources/acme-sh-renew.service.template             systemd renewal unit
resources/acme-sh-renew.timer.template               daily randomized timer
tests/test-cert.sh                                   lib/cert.sh unit tests (~21 cases)
tests/test-webserver-ssl-integration.sh              _reload_cmd_for_backend tests (~4 cases)
```

### Modified files

```
features/feature-webserver-ssl.sh                    delete ~130 LOC, add ~50 LOC delegation +
                                                     multi-name handling; II_VERSION 4 → 5;
                                                     vhost cert paths to /etc/acme.sh/<primary>/
features/feature-caddy.sh                            multi-name Caddyfile site blocks + self-signed
                                                     fallback CN/SAN update; II_VERSION bump
README.md                                            update SSL/HTTPS section to mention acme.sh +
                                                     comma-delimited WEBSERVER_SERVER_NAME syntax
config/webserver.config                              update WEBSERVER_SERVER_NAME comment to
                                                     document the new syntax
overrides/configuration.override.example             update WEBSERVER_SERVER_NAME comment to match
VERSION                                              PATCH per phase; MINOR on landing (target 2.10.0)
```

### Untouched

```
config/webserver.config                              same 4 SSL editable keys, same meanings
config/installicious.config                          unchanged
roles/*.sh                                           unchanged
docs/webserver-ssl-policy-matrix.md                  unchanged (HTTP policies unchanged)
features/feature-webserver-ssl.choices.sh            unchanged (radio + helpers same)
```

## Architecture

### `lib/cert.sh` — shared cert lifecycle

Five public functions designed to be drop-in replacements for the four
cert-related internal helpers currently inside feature-webserver-ssl.sh,
plus one new function for renewal-timer install.

```bash
cert_install_acme_sh
    # Idempotent install of acme.sh at /opt/acme.sh.
    # Three states handled:
    #   1. /opt/acme.sh missing  → wget the install script, pipe to sh with
    #      --home /opt/acme.sh --no-cron --noprofile email="$CERT_EMAIL".
    #      acme.sh's installer auto-registers an LE account with that email.
    #   2. /opt/acme.sh present, account email matches CERT_EMAIL → no-op.
    #   3. /opt/acme.sh present, account email differs from CERT_EMAIL →
    #      /opt/acme.sh/acme.sh --update-account --accountemail "$CERT_EMAIL".
    # Email-comparison reads ACCOUNT_EMAIL= from /opt/acme.sh/account.conf
    # via grep.
    # apt_ensure_installed wget runs before any of the above.
    # Auto-upgrade of acme.sh itself NOT performed (user runs --upgrade
    # explicitly if they want it).

cert_issue <primary_name> <method> [<san>...]
    # Run acme.sh --issue. <method> ∈ {http, dns-cloudflare}.
    # First positional is the primary domain (cert path is keyed on it);
    # subsequent positionals become SAN entries on the same cert.
    #
    # Each name is passed as a separate `-d` flag to acme.sh:
    #   http           → /opt/acme.sh/acme.sh --issue \
    #                       -d <primary> [-d <san>...] \
    #                       --webroot "$WEBSERVER_DOC_ROOT"
    #   dns-cloudflare → CF_Token="$CERT_CF_TOKEN" \
    #                    /opt/acme.sh/acme.sh --issue \
    #                       -d <primary> [-d <san>...] --dns dns_cf
    #
    # Wildcard names (any starting with "*.") REQUIRE method=dns-cloudflare.
    # Let's Encrypt rejects wildcards via HTTP-01; cert_issue fails fast
    # with a clear log_fail if a wildcard SAN appears with method=http.
    #
    # After successful issuance, write $PATH_STATE/acme-sh-creds.sh with
    # `export CF_Token="<the token>"` so the renewal systemd unit can
    # source it (belt-and-suspenders against acme.sh's per-domain conf
    # losing the token via --update-account ops).
    # Mode 0600 root:root.

cert_install_to_paths <name> <fullchain_path> <key_path> <reloadcmd>
    # /opt/acme.sh/acme.sh --install-cert \
    #   --fullchain-file <fullchain_path> \
    #   --key-file <key_path> \
    #   --reloadcmd <reloadcmd>
    # Idempotent — acme.sh overwrites the deployed files on every renewal.
    # The reloadcmd string is stored in acme.sh's per-domain conf and
    # runs after every successful renewal (no installicious involvement
    # at renewal time).

cert_renew_setup <name>
    # Render acme-sh-renew.{service,timer} from the templates in
    # $PATH_RESOURCES, install to /etc/systemd/system/ (mode 0644 root:root),
    # daemon-reload + enable --now the timer. Idempotent: re-render every
    # call but only reload+restart when content changed.
    # <name> is currently informational (the timer runs acme.sh's global
    # --cron mode which scans every issued cert).

cert_uninstall <name>
    # Reverse of install.
    # 1. systemctl disable --now acme-sh-renew.timer
    # 2. rm -f $PATH_STATE/acme-sh-creds.sh
    # 3. /opt/acme.sh/acme.sh --remove -d <name>
    # 4. rm -rf /etc/acme.sh/<name>/
    # 5. /opt/acme.sh/ left intact (idempotent re-install; may host other
    #    domains a future feature manages).
    # No legacy certbot cleanup — user confirmed no installs need it.

cert_verify <name>
    # Returns rc=0 if all hold:
    #   /etc/acme.sh/<name>/fullchain.pem exists
    #   /etc/acme.sh/<name>/privkey.pem exists
    #   openssl x509 -in fullchain.pem -checkend 0 returns rc=0
    #   /opt/acme.sh/acme.sh --list shows <name>
    #   systemctl is-active acme-sh-renew.timer returns rc=0
    # Each failing check emits a descriptive log_warn.

cert_parse_names <csv_string>
    # Echoes whitespace-separated names, one per line, with leading and
    # trailing whitespace trimmed per entry. Empty entries (e.g. trailing
    # comma) are dropped. Read-only / side-effect-free.

cert_validate_names <name>...
    # SHAPE-ONLY validation. Returns rc=0 if all <name>s pass:
    #   - Non-empty list (at least one name).
    #   - Each name matches hostname regex (allows leading '*.').
    # On failure: log_fail with the specific reason + return 1.
    # Wildcard-vs-method gating is NOT here — see cert_strip_wildcards.

cert_strip_wildcards <reason> <name>...
    # Echoes the input list with wildcard names (those starting with '*.')
    # removed, one name per line. For each stripped name, emits log_warn
    # quoting <reason> ("HTTP-01 cannot issue wildcard certs" or
    # "Caddy wildcard support not currently available", etc.).
    # Side-effect: log_warn output per stripped entry. Does NOT error or
    # return non-zero — the caller decides what to do with an empty result.
    # Used in the two "wildcards unsupported" contexts:
    #   - feature-webserver-ssl.sh with WEBSERVER_SSL_METHOD=http
    #   - feature-caddy.sh (any method)

cert_require_nonempty <name>...
    # Trivial guard. Returns rc=0 if the list is non-empty, rc=1 with
    # log_fail otherwise. Used after cert_strip_wildcards to detect the
    # "only wildcards were listed" failure case.
```

### Input variables (read from caller's env)

| Var | Purpose | Required for |
|---|---|---|
| `CERT_EMAIL` | LE account-registration email; one-time, updatable | `cert_install_acme_sh` only |
| `CERT_CF_TOKEN` | Cloudflare API token | `cert_issue` when method=dns-cloudflare |
| `WEBSERVER_DOC_ROOT` | Webroot for HTTP-01 challenges | `cert_issue` when method=http |

The caller (`feature-webserver-ssl.sh`) exports these from `WEBSERVER_SSL_EMAIL`,
`WEBSERVER_SSL_CF_TOKEN`, and `WEBSERVER_DOC_ROOT` before delegating.

### State + token storage

Three places store the CF token across the cert lifecycle:

| Location | Purpose | Written by | Mode | Removed at uninstall |
|---|---|---|---|---|
| `state/menu-config.sh` (existing) | User's persisted `WEBSERVER_SSL_CF_TOKEN` edit | `menu_edit_config` | 0600 root | yes (whole file managed by framework) |
| `/opt/acme.sh/<domain>/<domain>.conf` (acme.sh native) | Renewal-time pickup, persisted by acme.sh on first successful issue | `cert_issue` (via `CF_Token` env var → acme.sh persists) | 0600 root (acme.sh default) | yes — step 3+4 of cert_uninstall |
| `state/acme-sh-creds.sh` (new) | Belt-and-suspenders sourced by acme-sh-renew.service | `cert_issue` after successful issuance | 0600 root | yes — step 2 of cert_uninstall |

The renewal systemd service sources `state/acme-sh-creds.sh` before
invoking `/opt/acme.sh/acme.sh --cron`. Even if acme.sh's per-domain
conf loses the token (rare, but reported after `--update-account` ops),
the env var is in scope at renewal time and the cron run picks it up.

`state/acme-sh-creds.sh` shape:

```bash
# Sourced by acme-sh-renew.service. Only the CF token lives here; the
# LE account email lives in /opt/acme.sh/account.conf.
export CF_Token="<the WEBSERVER_SSL_CF_TOKEN value>"
```

Note: `CF_Token` (leading capital, no underscore) — the exact env var
name acme.sh's `dns_cf` plugin reads.

Atomic write via `mktemp` + `mv` in the same dir, mirroring
`lib/state.sh`'s `_state_write_pairs`. `chmod 0600` + `chown root:root`
post-rename.

### Systemd templates

`resources/acme-sh-renew.service.template`:

```ini
[Unit]
Description=Renew acme.sh-managed certificates
Documentation=https://github.com/acmesh-official/acme.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-{PATH_STATE}/acme-sh-creds.sh
ExecStart={ACME_SH_HOME}/acme.sh --cron --home {ACME_SH_HOME}

SuccessExitStatus=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc/acme.sh {ACME_SH_HOME} {PATH_STATE}
ProtectHome=true
```

`resources/acme-sh-renew.timer.template`:

```ini
[Unit]
Description=Daily check + renew acme.sh certificates
Documentation=https://github.com/acmesh-official/acme.sh

[Timer]
OnCalendar=daily
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
```

Marker substitution at install time:

```bash
sed -e "s|{PATH_STATE}|${PATH_STATE}|g" \
    -e "s|{ACME_SH_HOME}|/opt/acme.sh|g" \
    "${PATH_RESOURCES}/acme-sh-renew.<unit>.template"
```

Pipe `|` as the substitution delimiter — forward-slashes are common in
the values.

`OnCalendar=daily` + `RandomizedDelaySec=12h` covers LE's renewal window
(30 days before expiry is the issuance trigger) while spreading load
across the day. `Persistent=true` catches up missed runs after Pi reboots.

`Type=oneshot` + `EnvironmentFile=-...` (leading `-` makes the file
optional, so the unit doesn't fail if it's somehow absent) +
`SuccessExitStatus=0` trusts acme.sh's exit code. Hardening sandbox
(NoNewPrivileges, PrivateTmp, ProtectSystem=strict, explicit
ReadWritePaths, ProtectHome) keeps the renewal sandboxed.

## Multi-domain + wildcard support

`WEBSERVER_SERVER_NAME` becomes a comma-delimited list of hostnames.
Whitespace around each entry is tolerated. The **first** entry is the
primary (cert path is keyed on it; the cert lands at
`/etc/acme.sh/<primary>/`). The rest become SANs on the same cert.

```bash
# Single (today's behavior — unchanged):
WEBSERVER_SERVER_NAME="example.com"

# Multi-SAN:
WEBSERVER_SERVER_NAME="example.com, www.example.com"
WEBSERVER_SERVER_NAME="example.com, www.example.com, api.example.com"

# Wildcard (requires WEBSERVER_SSL_METHOD=dns-cloudflare):
WEBSERVER_SERVER_NAME="example.com, *.example.com"
WEBSERVER_SERVER_NAME="*.example.com"
```

### Parsing helper in `lib/cert.sh`

```bash
cert_parse_names <csv_string>
    # Echoes whitespace-separated names, one per line, with leading +
    # trailing whitespace trimmed per entry. Empty entries (e.g. trailing
    # comma) are dropped. Used by the feature's _obtain_cert to split
    # WEBSERVER_SERVER_NAME into an array.
```

Caller pattern:

```bash
mapfile -t NAMES < <(cert_parse_names "$WEBSERVER_SERVER_NAME")
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
cert_issue "$primary" "$WEBSERVER_SSL_METHOD" "${sans[@]}"
```

### Validation + wildcard-stripping gate

Runs at the top of `_obtain_cert` in `feature-webserver-ssl.sh` and at
the equivalent point in `feature-caddy.sh`. Two-stage shape:

#### Stage 1: shape validation (always)

1. **At least one name.** `WEBSERVER_SERVER_NAME` after parsing must
   yield ≥1 non-empty entry. Otherwise: `log_fail` "no server names
   configured" + return 1.
2. **Each name looks like a hostname.** Regex:
   `^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$`.
   This accepts `example.com`, `sub.example.com`, `*.example.com`. Rejects
   trailing dots, leading hyphens, empty labels.

#### Stage 2: wildcard handling (context-dependent)

Three contexts:

- **webserver-ssl + method=dns-cloudflare** — wildcards are supported.
  Keep all names. No filtering.
- **webserver-ssl + method=http** — HTTP-01 cannot issue wildcards.
  Strip them with a warning per stripped entry; error only if the result
  is empty.
- **Caddy backend (any method)** — Caddy wildcard support is deferred
  (see non-goals). Strip wildcards with a warning per stripped entry;
  error only if the result is empty.

The "strip with warning, error only when empty" rule means a user with
`example.com, *.example.com` on a Caddy backend gets a clean install of
`example.com` plus a `log_warn` explaining the wildcard was dropped — not
a hard failure. But a user with `*.example.com` alone on Caddy gets a
`log_fail` (nothing left to install).

#### Stage 3: backend-specific cred check

- **DNS-Cloudflare requires `WEBSERVER_SSL_CF_TOKEN`.** Existing check;
  reaffirmed here. Fires regardless of wildcard presence.

### Per-backend vhost rendering

| Backend | Single-name (today) | Multi-name (new) |
|---|---|---|
| nginx | `server_name example.com;` | `server_name example.com www.example.com *.example.com;` (space-separated) |
| apache | `ServerName example.com` | `ServerName example.com` <br> `ServerAlias www.example.com *.example.com` (one ServerAlias line listing the rest) |
| lighttpd | `$HTTP["host"] == "example.com"` block | `$HTTP["host"] =~ "^(example\.com\|www\.example\.com\|.*\.example\.com)$"` (regex; dots escaped, `*` converted to `.*`) |
| Caddy | `example.com { ... }` | `example.com, www.example.com { ... }` (Caddyfile site block accepts comma-separated names natively) |

The lighttpd regex assembly is the one place that needs care:

```bash
_lighttpd_hosts_regex() {
  # Echo "^(name1|name2|...)$" with regex-safe escaping.
  local -a parts=()
  local n
  for n in "$@"; do
    # Escape regex metacharacters. The only one in real hostnames is `.`;
    # `*` (wildcards) becomes `.*` so *.example.com matches any subdomain.
    parts+=("$(printf '%s' "$n" | sed 's/\./\\./g; s/\*/.*/g')")
  done
  local IFS='|'
  echo "^(${parts[*]})\$"
}
```

### Caddy self-signed fallback cert

Today, `feature-caddy.sh` generates a self-signed fallback cert with
`CN=$WEBSERVER_SERVER_NAME` and `subjectAltName=DNS:$WEBSERVER_SERVER_NAME`.
With multi-name: CN is the primary; subjectAltName is a comma-separated
list of all names. The openssl `-addext` call becomes:

```bash
-addext "subjectAltName=DNS:${primary},DNS:${san1},DNS:${san2}..."
```

### Editable-key documentation

`config/webserver.config` comment block for `WEBSERVER_SERVER_NAME`:

```bash
# Vhost name(s). Single hostname, or comma-separated list for multi-SAN
# certs. First entry is the primary (cert path is keyed on it).
# Wildcards (*.example.com) require WEBSERVER_SSL_METHOD=dns-cloudflare —
# Let's Encrypt rejects wildcards via HTTP-01. Wildcards on the Caddy
# backend are NOT supported today (requires Caddy 2.7+ caddy-dns/cloudflare
# plugin — deferred to a future feature-caddy update).
# Examples:
#   example.com
#   example.com, www.example.com
#   example.com, *.example.com    (acme.sh backends only)
WEBSERVER_SERVER_NAME=""
```

Mirror the same comment block in
`overrides/configuration.override.example`'s WEBSERVER_SERVER_NAME entry.

## `feature-webserver-ssl.sh` integration

Approx 130 LOC removed, replaced with ~40 LOC of `lib/cert.sh` delegation
plus a new `_reload_cmd_for_backend` helper.

### Replaced regions

| Lines | Before | After |
|---|---|---|
| 85, 90 | `WEBSERVER_SSL_CF_TOKEN` + `CLOUDFLARE_CREDS_FILE` constant | Same WEBSERVER_SSL_CF_TOKEN; remove the cloudflare.ini path constant |
| 97-99 | `_CERTBOT_ENV PendingDeprecationWarning` workaround | DELETE — acme.sh has no equivalent issue |
| 141-187 | `_write_cf_credentials`, `_remove_cf_credentials`, `_build_certonly_args` | DELETE — replaced by lib/cert.sh's `CF_Token` env-var flow |
| 482-508 | `_obtain_cert` (certbot invocation block) | REWRITTEN as a thin wrapper that exports CERT_* and calls cert_install_acme_sh / cert_issue / cert_install_to_paths / cert_renew_setup |
| 270-271, 385-386, 451-452 | nginx/apache/lighttpd vhost SSL paths pointing at `/etc/letsencrypt/live/<name>/` | Paths point at `/etc/acme.sh/<name>/` |
| 693-707 | `do_uninstall` — certbot apt revert + cloudflare.ini removal | REPLACED with `cert_uninstall "$WEBSERVER_SERVER_NAME"` |

### New helper

```bash
_reload_cmd_for_backend() {
  if   apt_is_installed nginx;    then echo "systemctl reload nginx"
  elif apt_is_installed apache2;  then echo "systemctl reload apache2"
  elif apt_is_installed lighttpd; then echo "systemctl reload lighttpd"
  else echo ":"   # no-op; cert is still issued, no backend to reload
  fi
}
```

Output is the string passed to `cert_install_to_paths` as the reloadcmd
argument. acme.sh stores it in the cert's per-domain conf and runs it
after each successful renewal.

### New `_obtain_cert` shape

```bash
_obtain_cert() {
  source lib/cert.sh
  CERT_EMAIL="$WEBSERVER_SSL_EMAIL"
  CERT_CF_TOKEN="$WEBSERVER_SSL_CF_TOKEN"
  export CERT_EMAIL CERT_CF_TOKEN

  # Parse multi-name list.
  local -a NAMES
  mapfile -t NAMES < <(cert_parse_names "$WEBSERVER_SERVER_NAME")

  # Stage 1: shape validation (always).
  cert_validate_names "${NAMES[@]}"                                       || return $?

  # Stage 2: strip wildcards when the chosen method can't issue them.
  if [[ $WEBSERVER_SSL_METHOD == "http" ]]; then
    mapfile -t NAMES < <(cert_strip_wildcards \
      "HTTP-01 cannot issue wildcard certs; switch to dns-cloudflare" \
      "${NAMES[@]}")
    cert_require_nonempty "${NAMES[@]}"                                   || return $?
  fi

  local primary="${NAMES[0]}"
  local sans=("${NAMES[@]:1}")

  cert_install_acme_sh                                                   || return $?
  cert_issue "$primary" "$WEBSERVER_SSL_METHOD" "${sans[@]}"             || return $?
  cert_install_to_paths "$primary" \
      "/etc/acme.sh/$primary/fullchain.pem" \
      "/etc/acme.sh/$primary/privkey.pem" \
      "$(_reload_cmd_for_backend)"                                       || return $?
  cert_renew_setup "$primary"
  return 0
}
```

Note: `cert_validate_names <method> <name>...` lives in `lib/cert.sh` and
handles the shape regex + wildcard-vs-method check. The Caddy-specific
"no wildcards" check is in `feature-caddy.sh`'s wrapper (it doesn't
belong in the lib, since the lib is webserver-agnostic).

### Manifest changes

`II_VERSION` bumps from `4` → `5` so existing installs re-run on next
installicious cycle and pick up the new code path. Per the project's
skip-hash convention, the feature also re-triggers on
`config/webserver.config` content changes.

`II_DEPS` stays empty — the parent webserver-ssl doesn't depend on any
apt package; `lib/cert.sh` itself runs `apt_ensure_installed wget` at
install time, and acme.sh isn't an apt package at all.

## `feature-caddy.sh` integration (multi-name only; wildcards out of scope)

`feature-caddy.sh` doesn't use `lib/cert.sh` — Caddy has its own built-in
ACME client. The changes here are limited to multi-name vhost rendering
and the self-signed fallback cert.

### Edits

| Where | Change |
|---|---|
| Top of install body (around line 78) | Parse `WEBSERVER_SERVER_NAME` via `cert_parse_names` (cert.sh is sourced for the parser + strip-helper, not for cert ops). |
| Validation + wildcard-strip block | `cert_validate_names "${NAMES[@]}"`. Then unconditionally strip wildcards via `cert_strip_wildcards "Caddy wildcard support not currently available (requires caddy add-package + caddy-dns/cloudflare; deferred)" "${NAMES[@]}"`. Then `cert_require_nonempty "${NAMES[@]}"` — error if every name was a wildcard, proceed otherwise. Set `primary` + `sans` array from the surviving names. |
| Self-signed fallback cert (around line 127-133) | `-subj "/CN=$primary"` + `-addext "subjectAltName=DNS:$primary,DNS:$san1,DNS:$san2..."`. Names array built from the parsed list. |
| Caddyfile templates (around lines 193, 240, 290) | Replace `${WEBSERVER_SERVER_NAME} {` with `${primary}, ${san1}, ${san2}... {`. Caddy accepts comma-separated names natively. |
| `@canonical host` matcher (line 199) | `@canonical host ${primary} ${san1} ${san2}...` (space-separated; Caddy's `host` matcher accepts a list of values, matches if any matches). |

`II_VERSION` on feature-caddy bumps by 1 so existing installs re-run on
next installicious cycle.

### What's deliberately NOT here

- No `caddy-dns/cloudflare` plugin install.
- No Caddyfile `tls { dns cloudflare }` block.
- No `CF_API_TOKEN` injection via systemd `Environment=`.
- No switch from Debian apt's `caddy` to Caddy's official APT repo.

All of the above are required for wildcard support on Caddy. They're
deferred to a separate feature-caddy update, captured in "Open
follow-ups" below.

## Data flow (end to end)

```
1. feature-webserver-ssl install body runs.
   ↓
2. Sources webserver.config, applies menu overrides, exports CERT_EMAIL +
   CERT_CF_TOKEN from the WEBSERVER_SSL_* values.
   ↓
3. _obtain_cert():
     cert_install_acme_sh        → idempotent acme.sh install at /opt/acme.sh,
                                    account registration with CERT_EMAIL.
     cert_issue <name> <method>  → acme.sh --issue (HTTP-01 via webroot OR
                                    DNS-Cloudflare via CF_Token env var).
                                    Writes state/acme-sh-creds.sh.
     cert_install_to_paths       → acme.sh --install-cert puts fullchain +
                                    privkey under /etc/acme.sh/<name>/ and
                                    stores the reloadcmd in the per-domain conf.
     cert_renew_setup            → installs acme-sh-renew.{service,timer}
                                    and enables the timer.
   ↓
4. _write_<backend>_site_config() (nginx/apache/lighttpd) renders the
   vhost referencing /etc/acme.sh/<name>/{fullchain,privkey}.pem.
   ↓
5. systemctl reload <backend>. HTTPS is live.
   ↓
6. Daily timer fires (with up-to-12h randomization). acme.sh --cron
   scans certs, renews any near-expiry, runs the stored reloadcmd
   after each successful renewal.
```

## Error handling

### Pre-install gates

`cert_install_acme_sh` performs:
- `apt_ensure_installed wget` — fail-fast with `log_fail` if apt itself
  refuses.
- Reachability check: `wget --spider -q https://get.acme.sh` — informational
  log_warn on failure but proceed to the pipe (lets a degraded network
  still succeed on retry).

`cert_issue` performs:
- HTTP-01: `$WEBSERVER_DOC_ROOT` is created if absent (existing behavior
  preserved from `_build_certonly_args`).
- DNS-Cloudflare: `CERT_CF_TOKEN` empty → `log_fail` + return 1 before
  shelling to acme.sh.

### Idempotence

- `cert_install_acme_sh` — three-state branch (absent / present-same-email
  / present-different-email).
- `cert_issue` — acme.sh's own `--issue` is idempotent (skips when a
  recently-issued cert is still valid; `--force` flag NOT used).
- `cert_install_to_paths` — acme.sh's `--install-cert` overwrites every
  time; no harm in re-running.
- `cert_renew_setup` — re-renders templates and only triggers
  `daemon-reload` on content change; `enable --now timer` is a no-op when
  already enabled.
- `cert_uninstall` — every step gracefully handles missing artifacts
  (`disable --now` of a missing timer is a no-op, `rm -f` of a missing
  file is a no-op).

### Resume / reboot

`cert_install_to_paths` does NOT require a reboot. `cert_renew_setup` does
NOT require a reboot. The whole feature's `II_REQUIRES_REBOOT="never"`
stays correct.

If installicious is interrupted mid-`_obtain_cert` (between cert_issue
succeeding and cert_install_to_paths failing), the cert exists in acme.sh's
registry but isn't deployed. Re-running the feature is safe: cert_issue
short-circuits on existing valid cert; cert_install_to_paths runs;
everything converges.

### Cert-issuance failures

acme.sh `--issue` failures:
- HTTP-01: port 80 not reachable from internet, webroot misconfigured,
  rate-limited by LE. acme.sh exits non-zero with a descriptive message;
  `_obtain_cert` returns that exit code; feature install fails with
  log_fail. User checks `/opt/acme.sh/acme.sh.log` for details.
- DNS-Cloudflare: token lacks `Zone:DNS:Edit`, zone not on this account,
  rate limit. Same exit-code propagation.

The feature does not retry. User re-runs installicious after fixing the
underlying issue.

## Testing strategy

### `tests/test-cert.sh` (new, ~250 lines)

Tempdir-isolated. Stubs `acme.sh`, `systemctl`, `apt-get`, `dpkg-query`,
`wget`, `openssl`, `sudo` via `$TEST_TMPDIR/bin` prepended to `PATH`.

Test hooks:
- `CERT_SKIP_REAL_NETWORK=true` — bypasses code paths that would shell
  out to real acme.sh or wget.
- `ACME_SH_HOME_OVERRIDE` — redirects `/opt/acme.sh` to a tempdir.
- `PATH_STATE`, `PATH_RESOURCES` redirected to tempdirs.

15 cases:

1. `cert_install_acme_sh` cold start — wget called once with install URL;
   acme.sh binary stub gets `--register-account --email <CERT_EMAIL>`.
2. `cert_install_acme_sh` idempotent same-email — account.conf shows
   matching ACCOUNT_EMAIL; wget NOT called, `--update-account` NOT called.
3. `cert_install_acme_sh` email change — account.conf shows different
   email; `--update-account --accountemail <new>` invoked exactly once.
4. `cert_issue` HTTP-01 — acme.sh called with `--issue -d <name> --webroot
   <doc_root>`; CF_Token NOT in env.
5. `cert_issue` DNS-Cloudflare — acme.sh called with `--issue -d <name>
   --dns dns_cf`; `CF_Token=<token>` in env (verified via stub env dump).
6. `cert_issue` writes `state/acme-sh-creds.sh` — file exists, mode 0600,
   contains `export CF_Token="<token>"`.
7. `cert_install_to_paths` — acme.sh called with `--install-cert
   --fullchain-file <p> --key-file <p> --reloadcmd <c>`.
8. `cert_renew_setup` cold start — service + timer files exist at
   `/etc/systemd/system/`, substitutions resolved, `daemon-reload` +
   `enable --now timer` invoked.
9. `cert_renew_setup` idempotent — re-run with no template change;
   `daemon-reload` NOT invoked the second time.
10. `cert_renew_setup` re-render on template change — change `PATH_STATE`,
    re-run; service file rewritten, daemon-reload triggered.
11. `cert_uninstall` full reverse — start with installed state; after call:
    timer disabled, creds file gone, `/etc/acme.sh/<name>/` gone, acme.sh
    stub called with `--remove -d <name>`, `/opt/acme.sh/` intact.
12. `cert_verify` healthy — cert pair exists, openssl-checkend stub
    succeeds, acme.sh `--list` includes name, timer is-active rc=0. rc=0.
13. `cert_verify` cert expired — openssl-checkend stub returns rc=1.
    cert_verify returns non-zero, log_warn names expiry.
14. `cert_verify` timer disabled — systemctl is-active stub returns
    inactive. cert_verify returns non-zero, log_warn names the timer.
15. `cert_verify` cert pair missing — `fullchain.pem` and/or `privkey.pem`
    don't exist under `/etc/acme.sh/<name>/`. cert_verify returns non-zero,
    log_warn names the missing path.
16. `cert_verify` not in acme.sh registry — `acme.sh --list` stub returns
    output that doesn't include `<name>`. cert_verify returns non-zero,
    log_warn names the de-registration.
17. Parameterized method coverage — loop over {http, dns-cloudflare},
    assert resulting acme.sh argv pattern matches the spec table.
18. `cert_parse_names` — comma-delimited input → array of trimmed names.
    Cases: single name, multi-name, whitespace tolerance, trailing comma,
    empty entry mid-list, all-whitespace input.
19. `cert_validate_names` shape pass — valid names: `example.com`,
    `sub.example.com`, `*.example.com`, `multi-hyphen-host.example.co.uk`.
    All return rc=0.
20. `cert_validate_names` shape reject — invalid names: empty string,
    `.example.com`, `example.com.` (trailing dot), `-leading-hyphen.com`,
    `space in name.com`. All return rc=1.
21. `cert_strip_wildcards` mixed list — input `example.com www.example.com
    *.example.com` produces output `example.com www.example.com` and one
    log_warn line quoting the reason.
22. `cert_strip_wildcards` all-wildcards — input `*.example.com
    *.api.example.com` produces empty output and two log_warn lines.
23. `cert_strip_wildcards` no-wildcards — input `example.com www.example.com`
    is returned unchanged with no log_warn output.
24. `cert_require_nonempty` empty — no args → rc=1 with log_fail.
25. `cert_require_nonempty` populated — one or more args → rc=0, no log.
26. `cert_issue` multi-SAN HTTP-01 — call with primary + 2 SANs +
    method=http. Assert acme.sh stub got `-d <p> -d <s1> -d <s2> --webroot`.
27. `cert_issue` multi-SAN DNS-Cloudflare — call with primary + wildcard
    SAN + method=dns-cloudflare. Assert acme.sh stub got
    `-d <p> -d *.<p> --dns dns_cf` and CF_Token in env.

### `tests/test-webserver-ssl-integration.sh` (new, ~200 lines)

NOT end-to-end. Unit-tests three helpers and the multi-name vhost
rendering for each backend:

**`_reload_cmd_for_backend`:**

1. With nginx installed (stubbed `apt_is_installed nginx` rc=0): emits
   `systemctl reload nginx`.
2. With apache2 installed: emits `systemctl reload apache2`.
3. With lighttpd installed: emits `systemctl reload lighttpd`.
4. With nothing installed: emits `:` (no-op).

**Multi-name vhost rendering (3 cases per backend = 9):**

5. nginx single-name: `server_name example.com;`.
6. nginx multi-SAN: `server_name example.com www.example.com api.example.com;`.
7. nginx wildcard: `server_name example.com *.example.com;`.
8. apache single-name: `ServerName example.com` + no `ServerAlias`.
9. apache multi-SAN: `ServerName example.com` + `ServerAlias www.example.com api.example.com`.
10. apache wildcard: `ServerName example.com` + `ServerAlias *.example.com`.
11. lighttpd single-name: regex `^(example\.com)$`.
12. lighttpd multi-SAN: regex `^(example\.com|www\.example\.com|api\.example\.com)$`.
13. lighttpd wildcard: regex `^(example\.com|.*\.example\.com)$`.

### `tests/test-caddy-integration.sh` (new, ~120 lines)

Unit-tests `feature-caddy.sh`'s multi-name handling:

1. Single-name Caddyfile: `example.com { ... }` (today's behavior preserved).
2. Multi-name Caddyfile: `example.com, www.example.com { ... }`.
3. Wildcard mixed with non-wildcards: input `example.com, *.example.com`
   produces a Caddyfile with `example.com { ... }` (wildcard stripped) and
   the install log contains one log_warn naming the stripped name.
4. All-wildcards: input `*.example.com, *.api.example.com` causes the
   install to return non-zero with a log_fail naming the empty result
   after stripping. Caddyfile is NOT written.
5. Self-signed fallback cert subjectAltName: multi-name input produces
   `subjectAltName=DNS:example.com,DNS:www.example.com` (only surviving
   names; wildcards excluded since the cert is self-signed and the names
   that matter for SNI are the non-wildcard ones).
6. `@canonical host` matcher: multi-name produces
   `@canonical host example.com www.example.com`.

### Existing test impact

| File | Change |
|---|---|
| `tests/test-manifest.sh` | None — feature manifest fields unchanged. II_VERSION bumps don't break the test. |
| `tests/test-role.sh` | None — webserver-ssl's role wiring unchanged. |
| `tests/test-verify.sh` | None — `verify_generic` already covers webserver-ssl. cert_verify is tested in test-cert.sh. |
| `tests/test-roundtrip.sh` | Confirm `CERT_SKIP_REAL_NETWORK=true` hook is plumbed; add stub if needed so the round-trip doesn't try to install acme.sh from the live network. |

Expected wall-clock impact on `bash tests/run.sh`: +20-30s.

## VERSION bump policy

PATCH per commit. Final landing commit MINOR-bumps (2.9.x → 2.10.0)
since this is a feature-complete substantive change.

## README / overrides-example updates

Per `feedback-readme-maintenance` memory: README's SSL/HTTPS section
gets updated to mention acme.sh instead of certbot. Per
`feedback-configuration-example-maintenance`: the 4 editable keys
(`WEBSERVER_SSL_EMAIL`, `WEBSERVER_SSL_METHOD`, `WEBSERVER_SSL_CF_TOKEN`,
`WEBSERVER_SSL_HTTP_POLICY`) keep their names and meanings, so the
overrides example needs no key changes — but the inline comment for
`WEBSERVER_SSL_METHOD` should be updated to mention the underlying
tool change ("via acme.sh, no Python dependencies").

## Open follow-ups (deferred, not blocking)

- **Wildcard certs on the Caddy backend.** Requires Caddy 2.7+ (Bookworm
  ships 2.6.2 — so a switch to Caddy's official APT repo at
  cloudsmith.io for both Bookworm and Trixie), plus `caddy add-package
  github.com/caddy-dns/cloudflare`, plus a Caddyfile `tls { dns
  cloudflare {env.CF_API_TOKEN} }` block, plus systemd `Environment=`
  injection of CF_API_TOKEN (or `EnvironmentFile=` from
  `state/caddy-cloudflare-creds.env`). Substantial enough to warrant its
  own brainstorm/spec/plan cycle — included in the current spec's
  non-goals.
- **`acme.sh --upgrade` cadence.** Today the install is locked at
  whatever acme.sh version was current at install time. Future:
  optional `WEBSERVER_SSL_ACME_AUTO_UPGRADE` knob that adds
  `--auto-upgrade` to the systemd unit. Off by default.
- **ZeroSSL fallback.** acme.sh defaults to LE but supports
  ZeroSSL/BuyPass. Could become a `WEBSERVER_SSL_CA` editable key
  (le / zerossl / buypass) if there's demand.
- **DNS provider plurality.** acme.sh supports 100+ DNS providers.
  Adding e.g. Route53 or DigitalOcean would be a parameter on
  cert_issue + an editable key for the provider name + credential vars.
