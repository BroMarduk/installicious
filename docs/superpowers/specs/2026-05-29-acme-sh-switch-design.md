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
- **Wildcard certificate support.** acme.sh handles wildcards via the
  same `--issue -d *.<name> --dns dns_cf` flow, but feature-webserver-ssl
  has no consumer for it today. Keep the API single-domain.
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
tests/test-cert.sh                                   lib/cert.sh unit tests (~17 cases)
tests/test-webserver-ssl-integration.sh              _reload_cmd_for_backend tests (~4 cases)
```

### Modified files

```
features/feature-webserver-ssl.sh                    delete ~130 LOC, add ~40 LOC delegation;
                                                     II_VERSION 4 → 5; vhost cert paths to /etc/acme.sh/
README.md                                            update SSL/HTTPS section to mention acme.sh
overrides/configuration.override.example             no change (key names + meanings preserved)
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

cert_issue <name> <method>
    # Run acme.sh --issue. <method> ∈ {http, dns-cloudflare}.
    #   http           → /opt/acme.sh/acme.sh --issue -d <name>
    #                       --webroot "$WEBSERVER_DOC_ROOT"
    #   dns-cloudflare → CF_Token="$CERT_CF_TOKEN" \
    #                    /opt/acme.sh/acme.sh --issue -d <name> --dns dns_cf
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

  cert_install_acme_sh                                                   || return $?
  cert_issue "$WEBSERVER_SERVER_NAME" "$WEBSERVER_SSL_METHOD"             || return $?
  cert_install_to_paths "$WEBSERVER_SERVER_NAME" \
      "/etc/acme.sh/$WEBSERVER_SERVER_NAME/fullchain.pem" \
      "/etc/acme.sh/$WEBSERVER_SERVER_NAME/privkey.pem" \
      "$(_reload_cmd_for_backend)"                                       || return $?
  cert_renew_setup "$WEBSERVER_SERVER_NAME"
  return 0
}
```

### Manifest changes

`II_VERSION` bumps from `4` → `5` so existing installs re-run on next
installicious cycle and pick up the new code path. Per the project's
skip-hash convention, the feature also re-triggers on
`config/webserver.config` content changes.

`II_DEPS` stays empty — the parent webserver-ssl doesn't depend on any
apt package; `lib/cert.sh` itself runs `apt_ensure_installed wget` at
install time, and acme.sh isn't an apt package at all.

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

### `tests/test-webserver-ssl-integration.sh` (new, ~80 lines)

NOT end-to-end. Just unit-tests `_reload_cmd_for_backend`:

1. With nginx installed (stubbed `apt_is_installed nginx` rc=0): emits
   `systemctl reload nginx`.
2. With apache2 installed: emits `systemctl reload apache2`.
3. With lighttpd installed: emits `systemctl reload lighttpd`.
4. With nothing installed: emits `:` (no-op).

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

- **`acme.sh --upgrade` cadence.** Today the install is locked at
  whatever acme.sh version was current at install time. Future:
  optional `WEBSERVER_SSL_ACME_AUTO_UPGRADE` knob that adds
  `--auto-upgrade` to the systemd unit. Off by default.
- **ZeroSSL fallback.** acme.sh defaults to LE but supports
  ZeroSSL/BuyPass. Could become a `WEBSERVER_SSL_CA` editable key
  (le / zerossl / buypass) if there's demand.
- **Wildcard certs.** Same acme.sh code path with `-d *.<name>`. Easy
  to enable later by adding an editable WEBSERVER_SSL_INCLUDE_WILDCARD
  toggle.
- **DNS provider plurality.** acme.sh supports 100+ DNS providers.
  Adding e.g. Route53 or DigitalOcean would be a parameter on
  cert_issue + an editable key for the provider name + credential vars.
