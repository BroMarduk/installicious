# acme.sh Switch + Multi-Domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `feature-webserver-ssl`'s certbot+python-cloudflare chain with acme.sh, extract cert lifecycle into a shared `lib/cert.sh`, and add comma-delimited multi-domain (incl. wildcard) support across all four webserver backends.

**Architecture:** New `lib/cert.sh` exposes `cert_*` primitives that wrap acme.sh's CLI. `feature-webserver-ssl.sh` becomes a thin orchestrator: parse comma-delimited `WEBSERVER_SERVER_NAME` → validate shape → strip-with-warn when wildcards aren't supportable → delegate to `cert_install_acme_sh`/`cert_issue`/`cert_install_to_paths`/`cert_renew_setup`. Vhost templates render multi-name `server_name` / `ServerAlias` / lighttpd-regex / Caddyfile site blocks. Cert files land at `/etc/acme.sh/<primary>/` (was `/etc/letsencrypt/live/<primary>/`). Daily renewal via a hardened systemd timer; acme.sh's `--reloadcmd` runs the right `systemctl reload <backend>` after each renewal. Caddy gets multi-name (free via Caddyfile syntax) but wildcard support is deferred (requires the `caddy-dns/cloudflare` plugin — out of scope for this plan).

**Tech Stack:** Bash 5; acme.sh (vendored via wget pipe to `/opt/acme.sh`); systemd timer + hardened service unit; Let's Encrypt over either HTTP-01 (webroot) or DNS-Cloudflare; openssl (for cert sanity check + self-signed fallback). Tests use the per-file inline `ok`/`fail`/`chkeq`/`chkrc` pattern + PATH-injected stubs for `acme.sh`, `systemctl`, `apt-get`, `dpkg-query`, `wget`, `openssl`, `sudo`.

**Branch:** `acme-sh` (created off `ai-refactor` at `1f529b0`). Spec at `docs/superpowers/specs/2026-05-29-acme-sh-switch-design.md`. VERSION starts at `2.9.5`; lands at `2.10.0` after Phase 7.

---

## Pre-flight checklist (read once before Phase 0)

- All work happens on the `acme-sh` branch. The branch exists locally + on origin and tracks upstream. **Verify before starting:** `git branch --show-current` should print `acme-sh`. If on `ai-refactor`, `git checkout acme-sh` first.
- After each phase: run the parallel test suite (`bash tests/run.sh`, ~2-3 min). Confirm `Total: N test(s), 0 failed`. **Always also run** `bash tests/test-<the-new-test>.sh 2>&1 | grep -E "^  FAIL"` — empty output is required because the parallel runner does NOT catch FAIL strings that don't `exit 1` (pre-existing framework quirk; see Phase 5 fix-up note in the RTC plan).
- Per-commit PATCH bump per [memory: installicious-version-bump](C:\Users\begal\.claude\projects\C--Source-Files-Personal-Bash-installicious\memory\installicious-version-bump.md). Final phase MINOR-bumps `2.9.x` → `2.10.0`.
- Every commit message ends with the trailer `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`. Pass commit messages via single-quoted HEREDOC.
- **Push after each commit** per [memory: feedback-push-default](C:\Users\begal\.claude\projects\C--Source-Files-Personal-Bash-installicious\memory\feedback-push-default.md). Push goes to `origin/acme-sh`, not `origin/ai-refactor`.
- Use the dedicated tools: `Edit`/`Write` over `sed`, `Grep` over `grep`, `Glob` over `find`.
- Reference patterns:
  - lib helper shape: [lib/rtc.sh](../../../lib/rtc.sh), [lib/boot-config.sh](../../../lib/boot-config.sh), [lib/state.sh](../../../lib/state.sh).
  - Stubbed-binary test pattern: [tests/test-rtc.sh](../../../tests/test-rtc.sh) (PATH-injected stubs, calls.log recording).
  - Atomic-write pattern: [lib/state.sh:32-50](../../../lib/state.sh#L32-L50) (`_state_write_pairs`).
  - Template-render pattern: existing `feature-caddy.sh` renders Caddyfiles inline; we follow the rendered-template-via-sed pattern for the systemd units.
- `/boot/firmware/` is irrelevant here — no overlay writes. `/etc/acme.sh/` and `/opt/acme.sh/` are the relevant paths on a real Pi. Tests use `mktemp -d` and `RTC_*`-style override env vars to bypass real paths on the Windows host.

---

## File structure

### New files

| Path | Purpose |
|---|---|
| `lib/cert.sh` | Shared cert lifecycle: install, issue, deploy, renew-setup, uninstall, verify + parsing/validation/stripping helpers. |
| `resources/acme-sh-renew.service.template` | Hardened systemd oneshot service that runs `acme.sh --cron`. |
| `resources/acme-sh-renew.timer.template` | Daily-with-12h-randomization timer driving the service. |
| `tests/test-cert.sh` | Unit tests for `lib/cert.sh` (~21 cases). |
| `tests/test-webserver-ssl-integration.sh` | Backend-rendering + reload-cmd tests (~13 cases). |
| `tests/test-caddy-integration.sh` | Caddyfile multi-name rendering + strip-and-warn tests (~6 cases). |

### Modified files

| Path | Change |
|---|---|
| `features/feature-webserver-ssl.sh` | -130 / +50 LOC: delete certbot helpers + sed workaround; add `_reload_cmd_for_backend` + new `_obtain_cert`; update vhost templates' cert paths; bump `II_VERSION` 4→5. |
| `features/feature-caddy.sh` | Multi-name parsing + strip-and-warn + Caddyfile multi-name + multi-SAN self-signed fallback; bump `II_VERSION`. |
| `config/webserver.config` | Update `WEBSERVER_SERVER_NAME` comment to document comma-delimited syntax + wildcard rules. |
| `overrides/configuration.override.example` | Mirror the `WEBSERVER_SERVER_NAME` comment. |
| `README.md` | SSL/HTTPS section: acme.sh instead of certbot; comma-delimited `WEBSERVER_SERVER_NAME`; wildcard rules. |
| `tests/test-manifest.sh` | Add `cert.sh` rosters if static lists exist (inspect first; framework discovers libs dynamically so likely no change). |
| `tests/test-verify.sh` | Confirm `verify_generic` still covers webserver-ssl (no change expected). |
| `VERSION` | PATCH per phase; MINOR on Phase 7. |

---

## Phase 0 — `lib/cert.sh` foundation helpers + tests (→ VERSION 2.9.6)

Ships the pure-bash helpers (no acme.sh interaction): name parsing, shape validation, wildcard stripping, empty-list guard. These are the building blocks the later phases compose into the cert lifecycle.

### Task 0.1: Create `lib/cert.sh` with foundation helpers

**Files:**
- Create: `lib/cert.sh`

- [ ] **Step 1: Write the file**

```bash
#!/bin/bash

# lib/cert.sh — shared cert lifecycle (acme.sh-backed) + supporting
# parse/validate/filter helpers consumed by feature-webserver-ssl.sh
# and feature-caddy.sh.
#
# Public API (added incrementally across phases 0-4):
#   cert_parse_names <csv_string>          # echo trimmed names, one per line
#   cert_validate_names <name>...          # shape-only; rc=0 if all valid
#   cert_strip_wildcards <reason> <name>...# echo non-wildcards; log_warn each stripped
#   cert_require_nonempty <name>...        # log_fail + rc=1 if empty, rc=0 otherwise
#   cert_install_acme_sh                   # phase 1
#   cert_issue / cert_install_to_paths     # phase 2
#   cert_renew_setup                       # phase 3
#   cert_verify                            # phase 4
#   cert_uninstall                         # phase 1
#
# Input env (set by caller before delegation):
#   CERT_EMAIL          LE account-registration email (cert_install_acme_sh)
#   CERT_CF_TOKEN       Cloudflare API token (cert_issue dns-cloudflare)
#   WEBSERVER_DOC_ROOT  HTTP-01 webroot (cert_issue http)

source config/installicious.config 2>/dev/null || true
source lib/log.sh 2>/dev/null || true

# cert_parse_names <csv_string>
# Echoes one name per line, with leading/trailing whitespace trimmed
# per entry. Empty entries (trailing comma, ", ,", purely-whitespace
# segments) are dropped. Side-effect-free.
cert_parse_names() {
  local csv="${1:-}"
  local IFS=',' part
  for part in $csv; do
    # Trim leading + trailing whitespace.
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n $part ]] && printf '%s\n' "$part"
  done
}

# cert_validate_names <name>...
# SHAPE-ONLY validation. rc=0 iff:
#   - argv is non-empty
#   - every <name> matches the hostname regex (allows leading "*." for
#     wildcards). Rejects empty, trailing-dot, leading-hyphen, embedded
#     whitespace, or empty labels.
# On failure: log_fail with the specific reason + rc=1.
# Wildcard-vs-method gating lives in cert_strip_wildcards, NOT here.
cert_validate_names() {
  if (( $# == 0 )); then
    declare -F log_fail >/dev/null \
      && log_fail "cert_validate_names: empty name list"
    return 1
  fi
  # Hostname regex: optional leading "*." then one+ labels separated by dots.
  # Each label: ASCII alnum, optional hyphens in the middle, no leading/
  # trailing hyphen, ≥1 char.
  local rx='^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
  local n
  for n in "$@"; do
    if ! [[ $n =~ $rx ]]; then
      declare -F log_fail >/dev/null \
        && log_fail "cert_validate_names: '$n' is not a valid hostname"
      return 1
    fi
  done
  return 0
}

# cert_strip_wildcards <reason> <name>...
# Echoes the input list with wildcards (names starting with "*.")
# removed, one per line. For each stripped name, emits log_warn quoting
# <reason>. Does NOT error or return non-zero — caller checks the
# resulting list (cert_require_nonempty for the "all-stripped" guard).
cert_strip_wildcards() {
  local reason="${1:-wildcards not supported in this context}"
  shift
  local n
  for n in "$@"; do
    if [[ $n == "*."* ]]; then
      declare -F log_warn >/dev/null \
        && log_warn "Dropping wildcard '$n' — $reason"
    else
      printf '%s\n' "$n"
    fi
  done
}

# cert_require_nonempty <name>...
# rc=0 if argv is non-empty; rc=1 + log_fail otherwise. Used after
# cert_strip_wildcards to detect "only wildcards were listed" failure.
cert_require_nonempty() {
  if (( $# == 0 )); then
    declare -F log_fail >/dev/null \
      && log_fail "cert_require_nonempty: no names remain — nothing to install (every entry was a wildcard the active backend cannot issue)"
    return 1
  fi
  return 0
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/cert.sh && echo OK`
Expected: `OK`

### Task 0.2: Write `tests/test-cert.sh` with foundation-helper coverage

**Files:**
- Create: `tests/test-cert.sh`

- [ ] **Step 1: Write the test file**

```bash
#!/bin/bash
# Tests for lib/cert.sh — foundation helpers (Phase 0) + later phases
# extend this file. Self-contained: tempdir-isolated, stub binaries via
# PATH injection.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/cert.sh

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPD=$(mktemp -d)
trap "rm -rf $TMPD" EXIT

# Stub log_* so tests can assert on emitted messages.
LOG_FILE="$TMPD/log.txt"
log_info() { echo "INFO $*" >> "$LOG_FILE"; }
log_warn() { echo "WARN $*" >> "$LOG_FILE"; }
log_fail() { echo "FAIL $*" >> "$LOG_FILE"; }
log_ok()   { echo "OK   $*" >> "$LOG_FILE"; }

_reset_log() { : > "$LOG_FILE"; }

# ---- Test 1: cert_parse_names ----
echo "=== Test 1: cert_parse_names ==="
chkeq "single name"          "$(cert_parse_names 'example.com' | tr '\n' '|')" "example.com|"
chkeq "multi name"           "$(cert_parse_names 'example.com,www.example.com' | tr '\n' '|')" "example.com|www.example.com|"
chkeq "whitespace tolerated" "$(cert_parse_names ' example.com , www.example.com ' | tr '\n' '|')" "example.com|www.example.com|"
chkeq "trailing comma"       "$(cert_parse_names 'example.com,' | tr '\n' '|')" "example.com|"
chkeq "empty entry mid-list" "$(cert_parse_names 'a.com,,b.com' | tr '\n' '|')" "a.com|b.com|"
chkeq "all whitespace"       "$(cert_parse_names '   ' | tr '\n' '|')" ""
chkeq "empty input"          "$(cert_parse_names '' | tr '\n' '|')" ""

# ---- Test 2: cert_validate_names shape pass ----
echo "=== Test 2: cert_validate_names shape pass ==="
cert_validate_names example.com
chkrc "single valid name" $? 0
cert_validate_names example.com www.example.com api.example.com
chkrc "multi valid names" $? 0
cert_validate_names '*.example.com'
chkrc "wildcard alone (shape OK; method gating elsewhere)" $? 0
cert_validate_names example.com '*.example.com'
chkrc "mixed valid + wildcard" $? 0
cert_validate_names host-with-hyphen.example.co.uk
chkrc "multi-label, hyphens in middle" $? 0

# ---- Test 3: cert_validate_names shape reject ----
echo "=== Test 3: cert_validate_names shape reject ==="
_reset_log
cert_validate_names
chkrc "empty arglist rejected" $? 1
grep -q 'empty name list' "$LOG_FILE"
chkrc "empty-list log_fail emitted" $? 0

_reset_log
cert_validate_names ''
chkrc "literal empty string rejected" $? 1

_reset_log
cert_validate_names '.example.com'
chkrc "leading-dot rejected" $? 1

_reset_log
cert_validate_names 'example.com.'
chkrc "trailing-dot rejected" $? 1

_reset_log
cert_validate_names '-leading-hyphen.com'
chkrc "leading-hyphen label rejected" $? 1

_reset_log
cert_validate_names 'space in name.com'
chkrc "embedded-whitespace rejected" $? 1

_reset_log
cert_validate_names 'no-tld'
chkrc "single-label (no TLD) rejected" $? 1

# ---- Test 4: cert_strip_wildcards mixed list ----
echo "=== Test 4: cert_strip_wildcards mixed list ==="
_reset_log
out=$(cert_strip_wildcards "test reason" example.com www.example.com '*.example.com' | tr '\n' '|')
chkeq "non-wildcards survive, wildcard dropped" "$out" "example.com|www.example.com|"
n=$(grep -c '^WARN' "$LOG_FILE")
chkeq "one log_warn line for the one wildcard" "$n" "1"
grep -q "Dropping wildcard '\*.example.com' — test reason" "$LOG_FILE"
chkrc "log_warn names the stripped entry + reason" $? 0

# ---- Test 5: cert_strip_wildcards all wildcards ----
echo "=== Test 5: cert_strip_wildcards all wildcards ==="
_reset_log
out=$(cert_strip_wildcards "test reason" '*.a.com' '*.b.com' | tr '\n' '|')
chkeq "all stripped → empty output" "$out" ""
n=$(grep -c '^WARN' "$LOG_FILE")
chkeq "two log_warn lines" "$n" "2"

# ---- Test 6: cert_strip_wildcards no wildcards ----
echo "=== Test 6: cert_strip_wildcards no wildcards ==="
_reset_log
out=$(cert_strip_wildcards "test reason" example.com www.example.com | tr '\n' '|')
chkeq "input unchanged" "$out" "example.com|www.example.com|"
n=$(grep -c '^WARN' "$LOG_FILE")
chkeq "no log_warn lines" "$n" "0"

# ---- Test 7: cert_require_nonempty ----
echo "=== Test 7: cert_require_nonempty ==="
_reset_log
cert_require_nonempty
chkrc "empty → fail" $? 1
grep -q '^FAIL' "$LOG_FILE"
chkrc "log_fail emitted for empty case" $? 0

_reset_log
cert_require_nonempty example.com
chkrc "single arg → pass" $? 0
n=$(grep -c '^FAIL' "$LOG_FILE")
chkeq "no log_fail for non-empty case" "$n" "0"

_reset_log
cert_require_nonempty a b c d e
chkrc "many args → pass" $? 0

echo
echo "=== Done ==="
```

- [ ] **Step 2: Make executable + run**

Run:
```
chmod +x tests/test-cert.sh
bash tests/test-cert.sh 2>&1 | tail -30
```
Expected: every line `OK …`, no `FAIL` lines, ending with `=== Done ===`.

- [ ] **Step 3: Confirm no masked FAILs (framework quirk guard)**

Run: `bash tests/test-cert.sh 2>&1 | grep -E "^  FAIL"`
Expected: empty output.

### Task 0.3: Run full suite + commit Phase 0

- [ ] **Step 1: Bump VERSION**

Write to `VERSION`:
```
2.9.6
```

- [ ] **Step 2: Parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed` (N grows by 1).

- [ ] **Step 3: Commit + push to origin/acme-sh**

```bash
git add VERSION lib/cert.sh tests/test-cert.sh
git commit -F- <<'MSG'
lib: cert.sh foundation helpers (parse, validate, strip-wildcards, require-nonempty)

Phase 0 of the acme.sh switch — ships the pure-bash building blocks
for the cert lifecycle. No acme.sh interaction yet; that arrives in
Phases 1-4.

  cert_parse_names <csv>           — split + trim WEBSERVER_SERVER_NAME-style
                                     comma-delimited input.
  cert_validate_names <name>...    — shape-only check (hostname regex,
                                     accepts leading "*.").
  cert_strip_wildcards <reason> ...— drop wildcards from a list with a
                                     log_warn per stripped entry.
  cert_require_nonempty <name>...  — log_fail + rc=1 if no args.

Tests in tests/test-cert.sh: 7 case groups, ~25 assertions covering
the trim/empty-handling/regex-pass/regex-reject/strip/require-nonempty
behaviors.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

- [ ] **Step 4: Confirm push**

Run: `git log --oneline -1 origin/acme-sh`
Expected: shows the new commit subject.

---

## Phase 1 — `cert_install_acme_sh` + `cert_uninstall` + state file (→ VERSION 2.9.7)

Adds the acme.sh install/account-management state machine + the uninstall reverse. No cert issuance yet (that's Phase 2). After this phase, calling `cert_install_acme_sh` on a fresh host wgets the install script, plants acme.sh at `/opt/acme.sh`, and registers an LE account with `$CERT_EMAIL`; calling it again is idempotent; calling it with a different `$CERT_EMAIL` updates the account.

### Task 1.1: Add `cert_install_acme_sh` to `lib/cert.sh`

**Files:**
- Modify: `lib/cert.sh` (append new functions)

- [ ] **Step 1: Append the functions**

Use `Edit` to append at the end of `lib/cert.sh`:

```bash

# ---------------------------------------------------------------------------
# acme.sh install lifecycle (Phase 1)
# ---------------------------------------------------------------------------

# Where acme.sh installs to. Tests override via ACME_SH_HOME_OVERRIDE.
_cert_acme_home() {
  echo "${ACME_SH_HOME_OVERRIDE:-/opt/acme.sh}"
}

# _cert_account_email — echo the account email currently registered in
# acme.sh's account.conf. Empty if no account.conf or no ACCOUNT_EMAIL=.
_cert_account_email() {
  local conf
  conf="$(_cert_acme_home)/account.conf"
  [[ -f $conf ]] || return 0
  # Source-style "ACCOUNT_EMAIL='foo@example.com'" lines.
  local line val
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ $line == "ACCOUNT_EMAIL="* ]]; then
      val=${line#ACCOUNT_EMAIL=}
      # Strip wrapping single or double quotes.
      if [[ ${val:0:1} == "'" && ${val: -1} == "'" ]]; then
        val=${val:1:${#val}-2}
      elif [[ ${val:0:1} == '"' && ${val: -1} == '"' ]]; then
        val=${val:1:${#val}-2}
      fi
      printf '%s' "$val"
      return 0
    fi
  done < "$conf"
}

# cert_install_acme_sh
# Idempotent. Three states:
#   1. acme.sh missing → wget install script, pipe to sh with
#      --home <home> --no-cron --noprofile email="$CERT_EMAIL".
#   2. acme.sh present, account email matches CERT_EMAIL → no-op.
#   3. acme.sh present, account email differs → run --update-account
#      --accountemail "$CERT_EMAIL".
# apt_ensure_installed wget runs first.
# Skipped network calls when CERT_SKIP_REAL_NETWORK=true (test hook):
# the install branch is bypassed; we assume the test seeded the home
# directory + account.conf.
cert_install_acme_sh() {
  if [[ -z "${CERT_EMAIL:-}" ]]; then
    declare -F log_fail >/dev/null \
      && log_fail "cert_install_acme_sh: CERT_EMAIL is empty"
    return 1
  fi

  local home
  home=$(_cert_acme_home)

  # Ensure wget is present.
  if declare -F apt_ensure_installed >/dev/null; then
    apt_ensure_installed wget || return $?
  fi

  if [[ ! -x "$home/acme.sh" ]]; then
    if [[ "${CERT_SKIP_REAL_NETWORK:-}" == "true" ]]; then
      declare -F log_warn >/dev/null \
        && log_warn "cert_install_acme_sh: CERT_SKIP_REAL_NETWORK=true; skipping wget pipe (test mode)"
    else
      declare -F log_info >/dev/null \
        && log_info "Installing acme.sh to $home (account email $CERT_EMAIL)."
      # The wget+pipe form lets acme.sh's official installer do account
      # registration with the passed-in email atomically with install.
      wget -O - https://get.acme.sh 2>/dev/null \
        | sh -s -- --home "$home" --no-cron --noprofile "email=$CERT_EMAIL" \
        || {
          declare -F log_fail >/dev/null \
            && log_fail "cert_install_acme_sh: install pipe failed (network? curl/wget? check journalctl)"
          return 1
        }
    fi
    return 0
  fi

  # acme.sh is present — check if account email matches.
  local current
  current=$(_cert_account_email)
  if [[ "$current" == "$CERT_EMAIL" ]]; then
    declare -F log_info >/dev/null \
      && log_info "acme.sh already installed at $home with matching account email."
    return 0
  fi

  declare -F log_info >/dev/null \
    && log_info "acme.sh account email changing from '$current' to '$CERT_EMAIL'; running --update-account."
  "$home/acme.sh" --update-account --accountemail "$CERT_EMAIL" --home "$home" \
    || {
      declare -F log_fail >/dev/null \
        && log_fail "cert_install_acme_sh: --update-account failed"
      return 1
    }
  return 0
}

# cert_uninstall <name>
# Reverse of install.
#   1. systemctl disable --now acme-sh-renew.timer
#   2. rm -f $PATH_STATE/acme-sh-creds.sh
#   3. <home>/acme.sh --remove -d <name>
#   4. rm -rf /etc/acme.sh/<name>/
#   5. <home> left intact (idempotent re-install; may host other domains).
# Each step gracefully no-ops on missing artifacts.
cert_uninstall() {
  local name="$1"
  if [[ -z "$name" ]]; then
    declare -F log_fail >/dev/null \
      && log_fail "cert_uninstall: name argument required"
    return 1
  fi

  # 1. Disable + stop renewal timer (no-op if absent).
  if systemctl list-unit-files acme-sh-renew.timer >/dev/null 2>&1; then
    systemctl disable --now acme-sh-renew.timer 2>/dev/null \
      || sudo systemctl disable --now acme-sh-renew.timer 2>/dev/null \
      || true
    declare -F log_info >/dev/null \
      && log_info "Disabled acme-sh-renew.timer."
  fi

  # 2. Remove belt-and-suspenders creds file.
  local creds="${PATH_STATE:-/etc/installicious/state}/acme-sh-creds.sh"
  if [[ -f $creds ]]; then
    rm -f "$creds" 2>/dev/null || sudo rm -f "$creds"
    declare -F log_info >/dev/null \
      && log_info "Removed $creds."
  fi

  # 3. De-register cert in acme.sh's registry.
  local home
  home=$(_cert_acme_home)
  if [[ -x "$home/acme.sh" ]]; then
    "$home/acme.sh" --remove -d "$name" --home "$home" 2>/dev/null \
      || sudo "$home/acme.sh" --remove -d "$name" --home "$home" 2>/dev/null \
      || true
    declare -F log_info >/dev/null \
      && log_info "Removed '$name' from acme.sh registry."
  fi

  # 4. Delete deployed cert pair.
  local deploy_dir="/etc/acme.sh/$name"
  if [[ -d $deploy_dir ]]; then
    rm -rf "$deploy_dir" 2>/dev/null || sudo rm -rf "$deploy_dir"
    declare -F log_info >/dev/null \
      && log_info "Removed $deploy_dir."
  fi

  return 0
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/cert.sh && echo OK`
Expected: `OK`

### Task 1.2: Extend `tests/test-cert.sh` with install/uninstall coverage

**Files:**
- Modify: `tests/test-cert.sh` (insert new cases before `=== Done ===`)

- [ ] **Step 1: Insert install-lifecycle stubs + tests**

Use `Edit` to insert before the `echo "=== Done ==="` line:

```bash

# ---------------------------------------------------------------------------
# Phase 1: cert_install_acme_sh + cert_uninstall
# ---------------------------------------------------------------------------

# Per-test PATH stub setup. Each Phase-1+ test resets the bin/ + state
# tempdirs to a known starting point.
PATH_STATE="$TMPD/state"
mkdir -p "$PATH_STATE"
mkdir -p "$TMPD/bin"

_reset_stubs() {
  rm -rf "$TMPD/bin" "$TMPD/acme-home" "$PATH_STATE"
  mkdir -p "$TMPD/bin" "$PATH_STATE"
  : > "$TMPD/calls.log"
}

_write_stub() {
  # _write_stub <name> <body>
  local name="$1" body="$2"
  cat > "$TMPD/bin/$name" <<EOF
#!/bin/bash
$body
EOF
  chmod +x "$TMPD/bin/$name"
}

# Common stub bodies.
_STUB_RECORD='echo "$0 $*" >> "'"$TMPD"'/calls.log"'

export ACME_SH_HOME_OVERRIDE="$TMPD/acme-home"
export PATH="$TMPD/bin:$PATH"

# apt_ensure_installed shim that just records the call (real lib not loaded).
apt_ensure_installed() { echo "apt_ensure_installed $*" >> "$TMPD/calls.log"; return 0; }

# ---- Test 8: cert_install_acme_sh — empty CERT_EMAIL ----
echo "=== Test 8: cert_install_acme_sh — empty CERT_EMAIL ==="
_reset_stubs
_reset_log
CERT_EMAIL="" cert_install_acme_sh
chkrc "empty CERT_EMAIL → rc=1" $? 1
grep -q "CERT_EMAIL is empty" "$LOG_FILE"
chkrc "log_fail names empty email" $? 0

# ---- Test 9: cert_install_acme_sh — cold install (test-mode shortcut) ----
echo "=== Test 9: cert_install_acme_sh — cold install (skip-network) ==="
_reset_stubs
_reset_log
# CERT_SKIP_REAL_NETWORK=true bypasses the wget pipe; we just verify
# the function returns 0 + records wget-ensure call.
CERT_EMAIL="user@example.com" CERT_SKIP_REAL_NETWORK=true cert_install_acme_sh
chkrc "cold install with skip-net → rc=0" $? 0
grep -q "apt_ensure_installed wget" "$TMPD/calls.log"
chkrc "wget apt-ensure recorded" $? 0
grep -q "CERT_SKIP_REAL_NETWORK=true" "$LOG_FILE"
chkrc "log_warn explains the skip" $? 0

# ---- Test 10: cert_install_acme_sh — idempotent (same email) ----
echo "=== Test 10: cert_install_acme_sh — idempotent same-email ==="
_reset_stubs
_reset_log
mkdir -p "$ACME_SH_HOME_OVERRIDE"
_write_stub "acme.sh-binary" "$_STUB_RECORD"
mv "$TMPD/bin/acme.sh-binary" "$ACME_SH_HOME_OVERRIDE/acme.sh"
chmod +x "$ACME_SH_HOME_OVERRIDE/acme.sh"
cat > "$ACME_SH_HOME_OVERRIDE/account.conf" <<'EOF'
ACCOUNT_EMAIL='user@example.com'
ACCOUNT_KEY_PATH='/opt/acme.sh/account.key'
EOF
CERT_EMAIL="user@example.com" cert_install_acme_sh
chkrc "matching email → rc=0" $? 0
grep -q -- "--update-account" "$TMPD/calls.log" \
  && fail "--update-account unexpectedly called" \
  || ok "no --update-account call (idempotent)"

# ---- Test 11: cert_install_acme_sh — email change triggers update ----
echo "=== Test 11: cert_install_acme_sh — email change ==="
_reset_stubs
_reset_log
mkdir -p "$ACME_SH_HOME_OVERRIDE"
_write_stub "acme.sh-binary" "$_STUB_RECORD"
mv "$TMPD/bin/acme.sh-binary" "$ACME_SH_HOME_OVERRIDE/acme.sh"
chmod +x "$ACME_SH_HOME_OVERRIDE/acme.sh"
cat > "$ACME_SH_HOME_OVERRIDE/account.conf" <<'EOF'
ACCOUNT_EMAIL='old@example.com'
EOF
CERT_EMAIL="new@example.com" cert_install_acme_sh
chkrc "email change → rc=0" $? 0
grep -q -- "--update-account --accountemail new@example.com" "$TMPD/calls.log"
chkrc "--update-account invoked with new email" $? 0

# ---- Test 12: cert_uninstall — full reverse ----
echo "=== Test 12: cert_uninstall — full reverse ==="
_reset_stubs
_reset_log
mkdir -p "$ACME_SH_HOME_OVERRIDE"
_write_stub "acme.sh-binary" "$_STUB_RECORD"
mv "$TMPD/bin/acme.sh-binary" "$ACME_SH_HOME_OVERRIDE/acme.sh"
chmod +x "$ACME_SH_HOME_OVERRIDE/acme.sh"
# Seed creds + deployed cert + a fake timer.
echo 'export CF_Token="seed-token"' > "$PATH_STATE/acme-sh-creds.sh"
chmod 0600 "$PATH_STATE/acme-sh-creds.sh"
mkdir -p "/tmp/test-acme-uninstall/etc/acme.sh/example.com" 2>/dev/null || true
# (We don't write to /etc/acme.sh in tests — the function rm -rfs whatever
# exists there, but the path is the production constant. The function
# logs but doesn't fail if the dir is absent.)
# Stub systemctl so the disable --now call is a no-op.
_write_stub "systemctl" "echo \"systemctl \$*\" >> \"$TMPD/calls.log\"; exit 0"

cert_uninstall example.com
chkrc "uninstall returns 0" $? 0
[[ -f "$PATH_STATE/acme-sh-creds.sh" ]] && fail "creds lingered" || ok "creds removed"
grep -q "acme.sh --remove -d example.com" "$TMPD/calls.log"
chkrc "acme.sh --remove invoked" $? 0

# ---- Test 13: cert_uninstall — missing artifacts gracefully no-op ----
echo "=== Test 13: cert_uninstall — missing artifacts ==="
_reset_stubs
_reset_log
_write_stub "systemctl" "echo \"systemctl \$*\" >> \"$TMPD/calls.log\"; exit 0"
cert_uninstall ghost.example.com
chkrc "uninstall against absent state → rc=0" $? 0
```

- [ ] **Step 2: Run the file**

Run: `bash tests/test-cert.sh 2>&1 | tail -30`
Expected: all OK; no FAIL.

- [ ] **Step 3: No-masked-FAIL check**

Run: `bash tests/test-cert.sh 2>&1 | grep -E "^  FAIL"`
Expected: empty.

### Task 1.3: Run full suite + commit Phase 1

- [ ] **Step 1: Bump VERSION to 2.9.7**

Write `2.9.7\n` to `VERSION`.

- [ ] **Step 2: Parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: Commit + push**

```bash
git add VERSION lib/cert.sh tests/test-cert.sh
git commit -F- <<'MSG'
lib: cert.sh — acme.sh install state machine + cert_uninstall

Phase 1. Adds:
  cert_install_acme_sh   — idempotent install via wget pipe; updates
                           account email if /opt/acme.sh exists with a
                           different ACCOUNT_EMAIL=. CERT_SKIP_REAL_NETWORK
                           env hook bypasses the network call for tests.
  cert_uninstall <name>  — reverses: disables timer, removes creds file,
                           runs acme.sh --remove, deletes /etc/acme.sh/<name>/.
                           Each step graceful on missing artifacts.

Helpers: _cert_acme_home (resolves $ACME_SH_HOME_OVERRIDE for tests vs
/opt/acme.sh production), _cert_account_email (parses ACCOUNT_EMAIL=
from /opt/acme.sh/account.conf).

Tests 8-13 in tests/test-cert.sh cover: empty-CERT_EMAIL guard, cold
install (test-mode), idempotent same-email, email-change → update-account,
full uninstall reverse, graceful uninstall on missing artifacts.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

---

## Phase 2 — `cert_issue` + `cert_install_to_paths` + creds-file write (→ VERSION 2.9.8)

The actual cert-issuance logic. Wraps `acme.sh --issue` for both HTTP-01 (webroot) and DNS-Cloudflare (CF_Token env var). Multi-SAN via variadic `-d` args. Wildcards-require-DNS-01 enforced at the lib layer. After successful issuance, writes `state/acme-sh-creds.sh` so the renewal systemd unit (Phase 3) can source the token. `cert_install_to_paths` runs `acme.sh --install-cert` to deploy the issued pair under `/etc/acme.sh/<primary>/`.

### Task 2.1: Add `cert_issue` to `lib/cert.sh`

**Files:**
- Modify: `lib/cert.sh` (append)

- [ ] **Step 1: Append the function**

Use `Edit` to append at the end of `lib/cert.sh`:

```bash

# ---------------------------------------------------------------------------
# Cert issuance (Phase 2)
# ---------------------------------------------------------------------------

# cert_issue <primary_name> <method> [<san>...]
# Run acme.sh --issue. <method> ∈ {http, dns-cloudflare}.
# Each name is passed as a separate `-d` flag. Wildcards in any position
# REQUIRE method=dns-cloudflare (LE rejects wildcards via HTTP-01).
# On success, writes $PATH_STATE/acme-sh-creds.sh (mode 0600 root:root)
# with `export CF_Token="<value>"` so the renewal systemd unit can source
# it independently of acme.sh's per-domain conf (belt-and-suspenders).
cert_issue() {
  local primary="$1" method="$2"
  shift 2
  local -a sans=("$@")

  if [[ -z "$primary" ]]; then
    declare -F log_fail >/dev/null \
      && log_fail "cert_issue: primary name required"
    return 1
  fi

  # Wildcard-vs-method gate: any wildcard requires dns-cloudflare.
  local n
  for n in "$primary" "${sans[@]}"; do
    if [[ $n == "*."* && $method != "dns-cloudflare" ]]; then
      declare -F log_fail >/dev/null \
        && log_fail "cert_issue: wildcard '$n' requires method=dns-cloudflare (HTTP-01 cannot issue wildcards); current method='$method'"
      return 1
    fi
  done

  local home
  home=$(_cert_acme_home)

  # Build argv: --issue -d <primary> [-d <san>...] + method flags.
  local -a argv=("$home/acme.sh" --issue -d "$primary")
  for n in "${sans[@]}"; do
    argv+=(-d "$n")
  done

  case "$method" in
    http)
      local webroot="${WEBSERVER_DOC_ROOT:-/var/www/html}"
      mkdir -p "$webroot" 2>/dev/null || sudo mkdir -p "$webroot"
      argv+=(--webroot "$webroot")
      ;;
    dns-cloudflare)
      if [[ -z "${CERT_CF_TOKEN:-}" ]]; then
        declare -F log_fail >/dev/null \
          && log_fail "cert_issue: CERT_CF_TOKEN required for method=dns-cloudflare"
        return 1
      fi
      argv+=(--dns dns_cf)
      ;;
    *)
      declare -F log_fail >/dev/null \
        && log_fail "cert_issue: unknown method '$method' (expected http or dns-cloudflare)"
      return 1
      ;;
  esac

  declare -F log_info >/dev/null \
    && log_info "Running: ${argv[*]} (primary=$primary, sans=${sans[*]:-none}, method=$method)"

  if [[ "$method" == "dns-cloudflare" ]]; then
    CF_Token="$CERT_CF_TOKEN" "${argv[@]}" || {
      declare -F log_fail >/dev/null \
        && log_fail "cert_issue: acme.sh --issue failed (rc=$?)"
      return 1
    }
  else
    "${argv[@]}" || {
      declare -F log_fail >/dev/null \
        && log_fail "cert_issue: acme.sh --issue failed (rc=$?)"
      return 1
    }
  fi

  # Belt-and-suspenders creds-file write (DNS-Cloudflare only).
  if [[ "$method" == "dns-cloudflare" ]]; then
    _cert_write_creds_file || return $?
  fi

  return 0
}

# _cert_write_creds_file
# Atomic write of $PATH_STATE/acme-sh-creds.sh containing
# `export CF_Token="<value>"`. Mode 0600, owner root.
_cert_write_creds_file() {
  local state="${PATH_STATE:-/etc/installicious/state}"
  local dest="$state/acme-sh-creds.sh"
  local tmp
  mkdir -p "$state" 2>/dev/null || sudo mkdir -p "$state"
  tmp=$(mktemp "$state/.acme-sh-creds.XXXXXX" 2>/dev/null) \
    || tmp=$(sudo mktemp "$state/.acme-sh-creds.XXXXXX")
  printf '# Generated by lib/cert.sh — DO NOT EDIT by hand.\n' > "$tmp" \
    || sudo tee "$tmp" > /dev/null < <(printf '# Generated by lib/cert.sh — DO NOT EDIT by hand.\n')
  printf 'export CF_Token=%q\n' "$CERT_CF_TOKEN" >> "$tmp" \
    || sudo tee -a "$tmp" > /dev/null < <(printf 'export CF_Token=%q\n' "$CERT_CF_TOKEN")
  chmod 0600 "$tmp" 2>/dev/null || sudo chmod 0600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || sudo chown root:root "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest" 2>/dev/null || sudo mv -f "$tmp" "$dest"
}

# cert_install_to_paths <name> <fullchain_path> <key_path> <reloadcmd>
# acme.sh --install-cert with the four deploy targets. Idempotent —
# acme.sh overwrites the deployed files on every renewal.
cert_install_to_paths() {
  local name="$1" fullchain="$2" key="$3" reloadcmd="$4"
  if [[ -z "$name" || -z "$fullchain" || -z "$key" ]]; then
    declare -F log_fail >/dev/null \
      && log_fail "cert_install_to_paths: name + fullchain + key required"
    return 1
  fi

  # Ensure the deploy directory exists.
  mkdir -p "$(dirname "$fullchain")" 2>/dev/null \
    || sudo mkdir -p "$(dirname "$fullchain")"

  local home
  home=$(_cert_acme_home)
  "$home/acme.sh" --install-cert -d "$name" \
    --fullchain-file "$fullchain" \
    --key-file "$key" \
    --reloadcmd "$reloadcmd" \
    --home "$home" \
    || {
      declare -F log_fail >/dev/null \
        && log_fail "cert_install_to_paths: acme.sh --install-cert failed (rc=$?)"
      return 1
    }

  declare -F log_info >/dev/null \
    && log_info "Deployed cert for $name → $fullchain / $key (reloadcmd: $reloadcmd)"
  return 0
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/cert.sh && echo OK`
Expected: `OK`

### Task 2.2: Extend `tests/test-cert.sh` with issue + install_to_paths coverage

**Files:**
- Modify: `tests/test-cert.sh` (insert before `=== Done ===`)

- [ ] **Step 1: Insert tests**

Use `Edit` to insert before the `echo "=== Done ==="` line:

```bash

# ---------------------------------------------------------------------------
# Phase 2: cert_issue + cert_install_to_paths
# ---------------------------------------------------------------------------

# Stub acme.sh binary that captures full argv + environment.
_install_acme_stub() {
  mkdir -p "$ACME_SH_HOME_OVERRIDE"
  cat > "$ACME_SH_HOME_OVERRIDE/acme.sh" <<'EOF'
#!/bin/bash
# Record argv as a single quoted line.
echo "ARGV: $*" >> "$CALLS_LOG"
# Record env vars of interest.
[[ -n "${CF_Token:-}" ]] && echo "ENV CF_Token=$CF_Token" >> "$CALLS_LOG"
exit 0
EOF
  chmod +x "$ACME_SH_HOME_OVERRIDE/acme.sh"
}

CALLS_LOG="$TMPD/calls.log"
export CALLS_LOG

# ---- Test 14: cert_issue HTTP-01 single name ----
echo "=== Test 14: cert_issue HTTP-01 single name ==="
_reset_stubs
_reset_log
_install_acme_stub
WEBSERVER_DOC_ROOT="$TMPD/webroot" cert_issue example.com http
chkrc "HTTP-01 single name → rc=0" $? 0
grep -q "ARGV: .*--issue -d example.com .*--webroot $TMPD/webroot" "$CALLS_LOG"
chkrc "argv has --issue + -d + --webroot" $? 0
grep -q "ENV CF_Token=" "$CALLS_LOG" \
  && fail "CF_Token leaked into HTTP-01 env" \
  || ok "no CF_Token in HTTP-01 env"

# ---- Test 15: cert_issue DNS-Cloudflare with CF_Token in env ----
echo "=== Test 15: cert_issue DNS-Cloudflare ==="
_reset_stubs
_reset_log
_install_acme_stub
CERT_CF_TOKEN="cf-secret-token" cert_issue example.com dns-cloudflare
chkrc "DNS-Cloudflare → rc=0" $? 0
grep -q "ARGV: .*--issue -d example.com .*--dns dns_cf" "$CALLS_LOG"
chkrc "argv has --dns dns_cf" $? 0
grep -q "ENV CF_Token=cf-secret-token" "$CALLS_LOG"
chkrc "CF_Token set in env for acme.sh" $? 0
[[ -f "$PATH_STATE/acme-sh-creds.sh" ]]
chkrc "creds file written" $? 0
grep -q "export CF_Token=" "$PATH_STATE/acme-sh-creds.sh"
chkrc "creds file contains export CF_Token=" $? 0

# ---- Test 16: cert_issue multi-SAN ----
echo "=== Test 16: cert_issue multi-SAN ==="
_reset_stubs
_reset_log
_install_acme_stub
WEBSERVER_DOC_ROOT="$TMPD/webroot" cert_issue example.com http www.example.com api.example.com
chkrc "multi-SAN → rc=0" $? 0
grep -q "ARGV: .*-d example.com -d www.example.com -d api.example.com" "$CALLS_LOG"
chkrc "argv has all three -d flags" $? 0

# ---- Test 17: cert_issue wildcard + dns-cloudflare ----
echo "=== Test 17: cert_issue wildcard + DNS-Cloudflare ==="
_reset_stubs
_reset_log
_install_acme_stub
CERT_CF_TOKEN="cf-secret-token" cert_issue example.com dns-cloudflare '*.example.com'
chkrc "wildcard + DNS-Cloudflare → rc=0" $? 0
grep -q "ARGV: .*-d example.com -d \*.example.com .*--dns dns_cf" "$CALLS_LOG"
chkrc "argv includes wildcard -d" $? 0

# ---- Test 18: cert_issue wildcard + HTTP-01 → rejected ----
echo "=== Test 18: cert_issue wildcard + HTTP-01 rejected ==="
_reset_stubs
_reset_log
_install_acme_stub
WEBSERVER_DOC_ROOT="$TMPD/webroot" cert_issue example.com http '*.example.com'
chkrc "wildcard + HTTP-01 → rc=1" $? 1
grep -q "wildcard '\*.example.com' requires method=dns-cloudflare" "$LOG_FILE"
chkrc "log_fail names the wildcard constraint" $? 0
grep -q "ARGV:" "$CALLS_LOG" \
  && fail "acme.sh called despite the rejection" \
  || ok "acme.sh NOT called"

# ---- Test 19: cert_issue DNS-Cloudflare with empty CERT_CF_TOKEN ----
echo "=== Test 19: cert_issue DNS-Cloudflare empty token ==="
_reset_stubs
_reset_log
_install_acme_stub
CERT_CF_TOKEN="" cert_issue example.com dns-cloudflare
chkrc "empty CERT_CF_TOKEN → rc=1" $? 1
grep -q "CERT_CF_TOKEN required" "$LOG_FILE"
chkrc "log_fail names the missing token" $? 0

# ---- Test 20: cert_issue unknown method ----
echo "=== Test 20: cert_issue unknown method ==="
_reset_stubs
_reset_log
_install_acme_stub
cert_issue example.com tls-alpn
chkrc "unknown method → rc=1" $? 1
grep -q "unknown method 'tls-alpn'" "$LOG_FILE"
chkrc "log_fail names the bad method" $? 0

# ---- Test 21: cert_install_to_paths ----
echo "=== Test 21: cert_install_to_paths ==="
_reset_stubs
_reset_log
_install_acme_stub
deploy="$TMPD/deploy/example.com"
cert_install_to_paths example.com "$deploy/fullchain.pem" "$deploy/privkey.pem" "systemctl reload nginx"
chkrc "install-to-paths → rc=0" $? 0
grep -q "ARGV: .*--install-cert -d example.com .*--fullchain-file $deploy/fullchain.pem .*--key-file $deploy/privkey.pem .*--reloadcmd systemctl reload nginx" "$CALLS_LOG"
chkrc "argv has all four deploy targets" $? 0
[[ -d "$deploy" ]]
chkrc "deploy directory created" $? 0
```

- [ ] **Step 2: Run the file**

Run: `bash tests/test-cert.sh 2>&1 | tail -30`
Expected: all OK; no FAIL.

- [ ] **Step 3: No-masked-FAIL check**

Run: `bash tests/test-cert.sh 2>&1 | grep -E "^  FAIL"`
Expected: empty.

### Task 2.3: Run full suite + commit Phase 2

- [ ] **Step 1: Bump VERSION to 2.9.8**

Write `2.9.8\n` to `VERSION`.

- [ ] **Step 2: Parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: Commit + push**

```bash
git add VERSION lib/cert.sh tests/test-cert.sh
git commit -F- <<'MSG'
lib: cert.sh — cert_issue + cert_install_to_paths + creds-file write

Phase 2. Adds:
  cert_issue <primary> <method> [<san>...]
    HTTP-01 (--webroot) or DNS-Cloudflare (--dns dns_cf, CF_Token in env).
    Multi-SAN via repeated -d. Wildcard in any position requires
    method=dns-cloudflare (LE rejects wildcards via HTTP-01).
    On DNS-Cloudflare success, writes state/acme-sh-creds.sh
    (0600 root) with `export CF_Token=...` for the Phase-3 renewal
    timer to source.

  cert_install_to_paths <name> <fullchain> <key> <reloadcmd>
    acme.sh --install-cert; idempotent. The reloadcmd string is stored
    in acme.sh's per-domain conf and runs after each successful renewal.

Tests 14-21 cover: HTTP-01 single, DNS-Cloudflare with CF_Token in env,
multi-SAN, wildcard + DNS, wildcard + HTTP rejected, empty CERT_CF_TOKEN
rejected, unknown method rejected, install-to-paths argv.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

---

## Phase 3 — Renewal systemd timer + `cert_renew_setup` (→ VERSION 2.9.9)

Templates + helper that drops a hardened systemd service + daily timer (with 12h randomization). Idempotent: re-render every call but only `daemon-reload` when content changed.

### Task 3.1: Create `resources/acme-sh-renew.service.template`

**Files:**
- Create: `resources/acme-sh-renew.service.template`

- [ ] **Step 1: Write the file**

```ini
[Unit]
Description=Renew acme.sh-managed certificates
Documentation=https://github.com/acmesh-official/acme.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Belt-and-suspenders: source the CF token in case acme.sh's per-domain
# conf lost it (e.g. via --update-account ops). The leading "-" makes
# the file optional so the unit doesn't fail if it's absent.
EnvironmentFile=-{PATH_STATE}/acme-sh-creds.sh
ExecStart={ACME_SH_HOME}/acme.sh --cron --home {ACME_SH_HOME}

SuccessExitStatus=0

# Hardening sandbox.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc/acme.sh {ACME_SH_HOME} {PATH_STATE}
ProtectHome=true
```

### Task 3.2: Create `resources/acme-sh-renew.timer.template`

**Files:**
- Create: `resources/acme-sh-renew.timer.template`

- [ ] **Step 1: Write the file**

```ini
[Unit]
Description=Daily check + renew acme.sh certificates
Documentation=https://github.com/acmesh-official/acme.sh

[Timer]
# Daily, with up-to-12h randomization so a fleet of Pis doesn't hit LE
# simultaneously. acme.sh --cron is idempotent and inexpensive when
# nothing is due for renewal.
OnCalendar=daily
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
```

### Task 3.3: Add `cert_renew_setup` to `lib/cert.sh`

**Files:**
- Modify: `lib/cert.sh` (append)

- [ ] **Step 1: Append the function**

Use `Edit` to append at the end of `lib/cert.sh`:

```bash

# ---------------------------------------------------------------------------
# Renewal systemd timer (Phase 3)
# ---------------------------------------------------------------------------

# cert_renew_setup <name>
# Render acme-sh-renew.{service,timer} from $PATH_RESOURCES, install to
# /etc/systemd/system/ (mode 0644 root:root), daemon-reload + enable
# --now the timer. Idempotent: re-render every call, only reload/restart
# on content change.
# <name> is currently informational (the timer runs --cron globally).
# Test hook: SYSTEMD_UNIT_DEST_OVERRIDE redirects the unit install dir
# for tests.
cert_renew_setup() {
  local name="${1:-}"
  local unit_dir="${SYSTEMD_UNIT_DEST_OVERRIDE:-/etc/systemd/system}"
  local resources="${PATH_RESOURCES:-resources}"
  local home
  home=$(_cert_acme_home)
  local state="${PATH_STATE:-/etc/installicious/state}"
  local svc_template="$resources/acme-sh-renew.service.template"
  local tmr_template="$resources/acme-sh-renew.timer.template"
  local svc_dest="$unit_dir/acme-sh-renew.service"
  local tmr_dest="$unit_dir/acme-sh-renew.timer"

  if [[ ! -f $svc_template || ! -f $tmr_template ]]; then
    declare -F log_fail >/dev/null \
      && log_fail "cert_renew_setup: template not found in $resources"
    return 1
  fi

  local tmp_svc tmp_tmr
  tmp_svc=$(mktemp)
  tmp_tmr=$(mktemp)

  # sed delimiter is | because PATH_STATE / ACME_SH_HOME contain /.
  sed -e "s|{PATH_STATE}|${state}|g" \
      -e "s|{ACME_SH_HOME}|${home}|g" \
      "$svc_template" > "$tmp_svc"
  sed -e "s|{PATH_STATE}|${state}|g" \
      -e "s|{ACME_SH_HOME}|${home}|g" \
      "$tmr_template" > "$tmp_tmr"

  mkdir -p "$unit_dir" 2>/dev/null || sudo mkdir -p "$unit_dir"

  local changed=0
  if ! cmp -s "$tmp_svc" "$svc_dest" 2>/dev/null; then
    install -m 0644 -o root -g root "$tmp_svc" "$svc_dest" 2>/dev/null \
      || sudo install -m 0644 -o root -g root "$tmp_svc" "$svc_dest"
    changed=1
  fi
  if ! cmp -s "$tmp_tmr" "$tmr_dest" 2>/dev/null; then
    install -m 0644 -o root -g root "$tmp_tmr" "$tmr_dest" 2>/dev/null \
      || sudo install -m 0644 -o root -g root "$tmp_tmr" "$tmr_dest"
    changed=1
  fi
  rm -f "$tmp_svc" "$tmp_tmr"

  if (( changed )); then
    systemctl daemon-reload 2>/dev/null \
      || sudo systemctl daemon-reload \
      || true
    declare -F log_info >/dev/null \
      && log_info "acme-sh-renew.{service,timer} (re)installed."
  fi

  systemctl enable --now acme-sh-renew.timer 2>/dev/null \
    || sudo systemctl enable --now acme-sh-renew.timer 2>/dev/null \
    || true

  return 0
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/cert.sh && echo OK`
Expected: `OK`

### Task 3.4: Extend `tests/test-cert.sh` with renewal coverage

**Files:**
- Modify: `tests/test-cert.sh` (insert before `=== Done ===`)

- [ ] **Step 1: Insert tests**

Use `Edit` to insert before the `echo "=== Done ==="` line:

```bash

# ---------------------------------------------------------------------------
# Phase 3: cert_renew_setup + systemd templates
# ---------------------------------------------------------------------------

# Stub systemctl to record calls (already used in Phase 1 tests, but
# we reset and re-stub here for clarity).
_install_systemctl_stub() {
  cat > "$TMPD/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS_LOG"
exit 0
EOF
  chmod +x "$TMPD/bin/systemctl"
}

# Test directory overrides.
export PATH_RESOURCES="resources"
export SYSTEMD_UNIT_DEST_OVERRIDE="$TMPD/units"

# ---- Test 22: cert_renew_setup cold install ----
echo "=== Test 22: cert_renew_setup cold install ==="
_reset_stubs
_reset_log
_install_acme_stub
_install_systemctl_stub
cert_renew_setup example.com
chkrc "cold renew-setup → rc=0" $? 0
[[ -f "$SYSTEMD_UNIT_DEST_OVERRIDE/acme-sh-renew.service" ]]
chkrc "service unit installed" $? 0
[[ -f "$SYSTEMD_UNIT_DEST_OVERRIDE/acme-sh-renew.timer" ]]
chkrc "timer unit installed" $? 0
grep -q "EnvironmentFile=-$PATH_STATE/acme-sh-creds.sh" "$SYSTEMD_UNIT_DEST_OVERRIDE/acme-sh-renew.service"
chkrc "PATH_STATE substitution applied" $? 0
grep -q "ExecStart=$ACME_SH_HOME_OVERRIDE/acme.sh --cron" "$SYSTEMD_UNIT_DEST_OVERRIDE/acme-sh-renew.service"
chkrc "ACME_SH_HOME substitution applied" $? 0
grep -q "systemctl daemon-reload" "$CALLS_LOG"
chkrc "daemon-reload triggered on first install" $? 0
grep -q "systemctl enable --now acme-sh-renew.timer" "$CALLS_LOG"
chkrc "timer enable+start invoked" $? 0

# ---- Test 23: cert_renew_setup idempotent re-run ----
echo "=== Test 23: cert_renew_setup idempotent ==="
# Don't reset — re-run on top of Test 22's state.
: > "$CALLS_LOG"
cert_renew_setup example.com
chkrc "re-run → rc=0" $? 0
grep -q "systemctl daemon-reload" "$CALLS_LOG" \
  && fail "daemon-reload re-triggered unnecessarily" \
  || ok "daemon-reload NOT re-triggered"

# ---- Test 24: cert_renew_setup re-render on template change ----
echo "=== Test 24: cert_renew_setup re-render on change ==="
_reset_log
: > "$CALLS_LOG"
# Force a content change by overriding PATH_STATE.
PATH_STATE="$TMPD/state-alt" mkdir -p "$TMPD/state-alt"
PATH_STATE="$TMPD/state-alt" cert_renew_setup example.com
grep -q "EnvironmentFile=-$TMPD/state-alt/acme-sh-creds.sh" "$SYSTEMD_UNIT_DEST_OVERRIDE/acme-sh-renew.service"
chkrc "service file rewritten" $? 0
grep -q "systemctl daemon-reload" "$CALLS_LOG"
chkrc "daemon-reload triggered on change" $? 0
```

- [ ] **Step 2: Run the file**

Run: `bash tests/test-cert.sh 2>&1 | tail -20`
Expected: all OK.

- [ ] **Step 3: No-masked-FAIL check**

Run: `bash tests/test-cert.sh 2>&1 | grep -E "^  FAIL"`
Expected: empty.

### Task 3.5: Run full suite + commit Phase 3

- [ ] **Step 1: Bump VERSION to 2.9.9**

Write `2.9.9\n` to `VERSION`.

- [ ] **Step 2: Parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: Commit + push**

```bash
git add VERSION lib/cert.sh tests/test-cert.sh resources/acme-sh-renew.service.template resources/acme-sh-renew.timer.template
git commit -F- <<'MSG'
lib: cert.sh — cert_renew_setup + hardened systemd unit templates

Phase 3. Adds:
  cert_renew_setup <name>
    Render resources/acme-sh-renew.{service,timer}.template, install
    to /etc/systemd/system/ (or $SYSTEMD_UNIT_DEST_OVERRIDE for tests),
    daemon-reload + enable --now the timer. Idempotent: only
    daemon-reload when content changed.

  resources/acme-sh-renew.service.template
    Type=oneshot. Sources PATH_STATE/acme-sh-creds.sh (optional
    via EnvironmentFile=-). Runs acme.sh --cron with the right --home.
    Hardened sandbox: NoNewPrivileges, PrivateTmp, ProtectSystem=strict,
    explicit ReadWritePaths, ProtectHome.

  resources/acme-sh-renew.timer.template
    OnCalendar=daily, RandomizedDelaySec=12h, Persistent=true.

Tests 22-24: cold install (both units present, daemon-reload + timer
enable invoked), idempotent re-run (no daemon-reload), re-render on
template variable change (rewrite + daemon-reload).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

---

## Phase 4 — `cert_verify` (→ VERSION 2.9.10)

Health check: cert pair exists, openssl says it's not expired, acme.sh registry knows about it, renewal timer is active.

### Task 4.1: Add `cert_verify` to `lib/cert.sh`

**Files:**
- Modify: `lib/cert.sh` (append)

- [ ] **Step 1: Append the function**

Use `Edit` to append at end of `lib/cert.sh`:

```bash

# ---------------------------------------------------------------------------
# Cert verification (Phase 4)
# ---------------------------------------------------------------------------

# cert_verify <name>
# Returns rc=0 if all hold:
#   1. /etc/acme.sh/<name>/fullchain.pem exists
#   2. /etc/acme.sh/<name>/privkey.pem exists
#   3. openssl x509 -in fullchain.pem -checkend 0 returns rc=0 (not expired)
#   4. <home>/acme.sh --list output includes <name>
#   5. systemctl is-active acme-sh-renew.timer returns rc=0
# Each failing check emits a descriptive log_warn. Returns rc=N where N
# is the count of failing checks.
# Test hooks:
#   CERT_DEPLOY_BASE_OVERRIDE  redirect /etc/acme.sh/ root.
#   SYSTEMD_TIMER_NAME_OVERRIDE  custom timer name for testing.
cert_verify() {
  local name="$1"
  if [[ -z "$name" ]]; then
    declare -F log_fail >/dev/null \
      && log_fail "cert_verify: name required"
    return 1
  fi
  local base="${CERT_DEPLOY_BASE_OVERRIDE:-/etc/acme.sh}"
  local fullchain="$base/$name/fullchain.pem"
  local key="$base/$name/privkey.pem"
  local home
  home=$(_cert_acme_home)
  local timer="${SYSTEMD_TIMER_NAME_OVERRIDE:-acme-sh-renew.timer}"
  local fails=0

  if [[ ! -f $fullchain ]]; then
    declare -F log_warn >/dev/null \
      && log_warn "cert_verify: fullchain missing at $fullchain"
    fails=$((fails + 1))
  fi
  if [[ ! -f $key ]]; then
    declare -F log_warn >/dev/null \
      && log_warn "cert_verify: privkey missing at $key"
    fails=$((fails + 1))
  fi
  if [[ -f $fullchain ]]; then
    if ! openssl x509 -in "$fullchain" -checkend 0 -noout >/dev/null 2>&1; then
      declare -F log_warn >/dev/null \
        && log_warn "cert_verify: $fullchain is expired (or openssl rejected it)"
      fails=$((fails + 1))
    fi
  fi
  if [[ -x "$home/acme.sh" ]]; then
    if ! "$home/acme.sh" --list --home "$home" 2>/dev/null | grep -qE "^$name(\b|\s)"; then
      declare -F log_warn >/dev/null \
        && log_warn "cert_verify: '$name' not in acme.sh --list (de-registered?)"
      fails=$((fails + 1))
    fi
  fi
  if ! systemctl is-active --quiet "$timer" 2>/dev/null; then
    declare -F log_warn >/dev/null \
      && log_warn "cert_verify: $timer is not active (renewal will not fire)"
    fails=$((fails + 1))
  fi

  return $fails
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/cert.sh && echo OK`
Expected: `OK`

### Task 4.2: Extend `tests/test-cert.sh` with verify coverage

**Files:**
- Modify: `tests/test-cert.sh` (insert before `=== Done ===`)

- [ ] **Step 1: Insert tests**

Use `Edit` to insert before the `echo "=== Done ==="` line:

```bash

# ---------------------------------------------------------------------------
# Phase 4: cert_verify
# ---------------------------------------------------------------------------

# Reuse _install_acme_stub for acme.sh --list. Modify the stub to
# emit a fixed list when --list is the first arg.
_install_acme_list_stub() {
  mkdir -p "$ACME_SH_HOME_OVERRIDE"
  cat > "$ACME_SH_HOME_OVERRIDE/acme.sh" <<'EOF'
#!/bin/bash
echo "ARGV: $*" >> "$CALLS_LOG"
if [[ "$1" == "--list" ]]; then
  # Two lines: header + one data row.
  cat <<L
Main_Domain  KeyLength  SAN_Domains  CA  Created  Renew
example.com  ec-256     www.example.com  LetsEncrypt.org  2026-05-01  2026-07-30
L
fi
exit 0
EOF
  chmod +x "$ACME_SH_HOME_OVERRIDE/acme.sh"
}

# Stub openssl: returns rc=0 (cert not expired) by default; tests that
# need expiry override the binary inline.
_install_openssl_stub_ok() {
  cat > "$TMPD/bin/openssl" <<'EOF'
#!/bin/bash
echo "openssl $*" >> "$CALLS_LOG"
exit 0
EOF
  chmod +x "$TMPD/bin/openssl"
}

_install_openssl_stub_expired() {
  cat > "$TMPD/bin/openssl" <<'EOF'
#!/bin/bash
echo "openssl $*" >> "$CALLS_LOG"
exit 1
EOF
  chmod +x "$TMPD/bin/openssl"
}

# systemctl stub: is-active returns rc=0 by default; override per-test.
_install_systemctl_active() {
  cat > "$TMPD/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS_LOG"
[[ "$1" == "is-active" ]] && exit 0
exit 0
EOF
  chmod +x "$TMPD/bin/systemctl"
}

_install_systemctl_inactive() {
  cat > "$TMPD/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS_LOG"
[[ "$1" == "is-active" ]] && exit 3
exit 0
EOF
  chmod +x "$TMPD/bin/systemctl"
}

export CERT_DEPLOY_BASE_OVERRIDE="$TMPD/acme-deploy"

# ---- Test 25: cert_verify healthy ----
echo "=== Test 25: cert_verify healthy ==="
_reset_stubs
_reset_log
_install_acme_list_stub
_install_openssl_stub_ok
_install_systemctl_active
mkdir -p "$CERT_DEPLOY_BASE_OVERRIDE/example.com"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/fullchain.pem"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/privkey.pem"
cert_verify example.com
chkrc "all checks pass → rc=0" $? 0

# ---- Test 26: cert_verify expired ----
echo "=== Test 26: cert_verify expired ==="
_reset_stubs
_reset_log
_install_acme_list_stub
_install_openssl_stub_expired
_install_systemctl_active
mkdir -p "$CERT_DEPLOY_BASE_OVERRIDE/example.com"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/fullchain.pem"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/privkey.pem"
cert_verify example.com
rc=$?
[[ $rc -ge 1 ]]
chkrc "expired → rc≥1" $? 0
grep -q "expired" "$LOG_FILE"
chkrc "log_warn names expiry" $? 0

# ---- Test 27: cert_verify cert pair missing ----
echo "=== Test 27: cert_verify cert pair missing ==="
_reset_stubs
_reset_log
_install_acme_list_stub
_install_openssl_stub_ok
_install_systemctl_active
# Don't create the cert files.
cert_verify ghost.example.com
rc=$?
[[ $rc -ge 1 ]]
chkrc "missing pair → rc≥1" $? 0
grep -q "fullchain missing" "$LOG_FILE"
chkrc "log_warn names missing fullchain" $? 0

# ---- Test 28: cert_verify timer disabled ----
echo "=== Test 28: cert_verify timer disabled ==="
_reset_stubs
_reset_log
_install_acme_list_stub
_install_openssl_stub_ok
_install_systemctl_inactive
mkdir -p "$CERT_DEPLOY_BASE_OVERRIDE/example.com"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/fullchain.pem"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/privkey.pem"
cert_verify example.com
rc=$?
[[ $rc -ge 1 ]]
chkrc "inactive timer → rc≥1" $? 0
grep -q "is not active" "$LOG_FILE"
chkrc "log_warn names inactive timer" $? 0

# ---- Test 29: cert_verify not in acme.sh registry ----
echo "=== Test 29: cert_verify not in registry ==="
_reset_stubs
_reset_log
# Custom stub: --list returns no rows.
mkdir -p "$ACME_SH_HOME_OVERRIDE"
cat > "$ACME_SH_HOME_OVERRIDE/acme.sh" <<'EOF'
#!/bin/bash
[[ "$1" == "--list" ]] && { echo "Main_Domain  KeyLength  SAN_Domains"; exit 0; }
exit 0
EOF
chmod +x "$ACME_SH_HOME_OVERRIDE/acme.sh"
_install_openssl_stub_ok
_install_systemctl_active
mkdir -p "$CERT_DEPLOY_BASE_OVERRIDE/example.com"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/fullchain.pem"
: > "$CERT_DEPLOY_BASE_OVERRIDE/example.com/privkey.pem"
cert_verify example.com
rc=$?
[[ $rc -ge 1 ]]
chkrc "missing from --list → rc≥1" $? 0
grep -q "not in acme.sh --list" "$LOG_FILE"
chkrc "log_warn names the de-registration" $? 0
```

- [ ] **Step 2: Run the file**

Run: `bash tests/test-cert.sh 2>&1 | tail -30`
Expected: all OK.

- [ ] **Step 3: No-masked-FAIL check**

Run: `bash tests/test-cert.sh 2>&1 | grep -E "^  FAIL"`
Expected: empty.

### Task 4.3: Run full suite + commit Phase 4

- [ ] **Step 1: Bump VERSION to 2.9.10**

Write `2.9.10\n` to `VERSION`.

- [ ] **Step 2: Parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: Commit + push**

```bash
git add VERSION lib/cert.sh tests/test-cert.sh
git commit -F- <<'MSG'
lib: cert.sh — cert_verify (5-check health)

Phase 4. Adds:
  cert_verify <name>
    Checks (each failure increments rc; descriptive log_warn per fail):
      1. /etc/acme.sh/<name>/fullchain.pem exists
      2. /etc/acme.sh/<name>/privkey.pem exists
      3. openssl x509 -checkend 0 says the cert is not expired
      4. acme.sh --list output includes <name>
      5. systemctl is-active acme-sh-renew.timer succeeds
    Returns rc=0 if all pass; rc=N (count of failures) otherwise.
    Test hooks: CERT_DEPLOY_BASE_OVERRIDE, SYSTEMD_TIMER_NAME_OVERRIDE.

Tests 25-29: healthy (rc=0), expired cert, missing cert pair, timer
disabled, not in acme.sh registry. Each failure case asserts on the
descriptive log_warn.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

---

## Phase 5 — `feature-webserver-ssl.sh` refactor + integration tests (→ VERSION 2.9.11)

The biggest phase. Removes ~130 LOC of certbot-specific code, replaces with ~50 LOC of `lib/cert.sh` delegation, updates the three vhost templates (nginx, apache, lighttpd) to handle multi-name + the new cert path, and adds `tests/test-webserver-ssl-integration.sh` covering the reload-cmd helper + multi-name vhost rendering.

### Task 5.1: Remove certbot-specific helpers from `feature-webserver-ssl.sh`

**Files:**
- Modify: `features/feature-webserver-ssl.sh`

- [ ] **Step 1: Inspect current state**

Run: `grep -n "_CERTBOT_ENV\|_write_cf_credentials\|_remove_cf_credentials\|_build_certonly_args\|CLOUDFLARE_CREDS_FILE" features/feature-webserver-ssl.sh`

Note the exact line numbers — they'll be needed for the Edit calls.

- [ ] **Step 2: Delete the `_CERTBOT_ENV` constant block**

Use `Edit` to remove the comment + assignment around line 97-99:

```
# Find this block:
# Suppress python3-cloudflare 2.20.x PendingDeprecationWarning that the
# certbot-dns-cloudflare plugin triggers; cert issuance is unaffected.
_CERTBOT_ENV=(env PYTHONWARNINGS=ignore::PendingDeprecationWarning)
```

Replace with nothing (delete the 3 lines).

- [ ] **Step 3: Delete the `CLOUDFLARE_CREDS_FILE` constant**

Use `Edit` to remove the line around 90:

```
CLOUDFLARE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/cloudflare.ini"
```

- [ ] **Step 4: Delete `_write_cf_credentials`, `_remove_cf_credentials`, `_build_certonly_args`**

Use `Edit` to remove the three functions (lines 141-187 in the original file). The block looks like:

```bash
_write_cf_credentials() {
  # ... ~17 lines
}

_remove_cf_credentials() {
  # ... ~10 lines
}

_build_certonly_args() {
  # ... ~19 lines
}
```

Delete the entire span — these are no longer needed; lib/cert.sh handles credentials via CF_Token env var and acme.sh handles argv via its --issue interface.

- [ ] **Step 5: Syntax-check**

Run: `bash -n features/feature-webserver-ssl.sh && echo OK`
Expected: `OK`

### Task 5.2: Rewrite `_obtain_cert` to delegate to `lib/cert.sh`

**Files:**
- Modify: `features/feature-webserver-ssl.sh`

- [ ] **Step 1: Find the current `_obtain_cert` body**

Run: `grep -n "^_obtain_cert()" features/feature-webserver-ssl.sh`

- [ ] **Step 2: Replace the function body**

Use `Edit` to replace the entire `_obtain_cert` function (the block from `_obtain_cert() {` through its closing `}`) with:

```bash
# Source lib/cert.sh once at top of file is preferred — but since we
# only need it during install, sourcing inside _obtain_cert keeps the
# verify / uninstall paths lean.
_obtain_cert() {
  source lib/cert.sh || {
    log_fail "_obtain_cert: lib/cert.sh failed to source"
    return 1
  }

  CERT_EMAIL="$WEBSERVER_SSL_EMAIL"
  CERT_CF_TOKEN="$WEBSERVER_SSL_CF_TOKEN"
  export CERT_EMAIL CERT_CF_TOKEN

  # Parse comma-delimited WEBSERVER_SERVER_NAME.
  local -a NAMES
  mapfile -t NAMES < <(cert_parse_names "$WEBSERVER_SERVER_NAME")

  # Stage 1: shape validation (always).
  cert_validate_names "${NAMES[@]}"                                       || return $?

  # Stage 2: strip wildcards when HTTP-01 can't issue them.
  if [[ $WEBSERVER_SSL_METHOD == "http" ]]; then
    mapfile -t NAMES < <(cert_strip_wildcards \
      "HTTP-01 cannot issue wildcard certs; switch to dns-cloudflare" \
      "${NAMES[@]}")
    cert_require_nonempty "${NAMES[@]}"                                   || return $?
  fi

  local primary="${NAMES[0]}"
  local sans=("${NAMES[@]:1}")

  cert_install_acme_sh                                                    || return $?
  cert_issue "$primary" "$WEBSERVER_SSL_METHOD" "${sans[@]}"              || return $?
  cert_install_to_paths "$primary" \
      "/etc/acme.sh/$primary/fullchain.pem" \
      "/etc/acme.sh/$primary/privkey.pem" \
      "$(_reload_cmd_for_backend)"                                        || return $?
  cert_renew_setup "$primary"
  return 0
}
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n features/feature-webserver-ssl.sh && echo OK`
Expected: `OK`

### Task 5.3: Add `_reload_cmd_for_backend` helper

**Files:**
- Modify: `features/feature-webserver-ssl.sh`

- [ ] **Step 1: Insert the helper**

Use `Edit` to insert just before `_obtain_cert`:

```bash
# _reload_cmd_for_backend
# Returns the systemctl reload command string for the active webserver
# backend. Passed to acme.sh's --install-cert --reloadcmd, which runs
# it after each successful renewal (hot-picks up the new cert without
# restart). Returns ":" (no-op) if no backend is installed — the cert
# is still issued, just no service to reload.
_reload_cmd_for_backend() {
  if   apt_is_installed nginx;    then echo "systemctl reload nginx"
  elif apt_is_installed apache2;  then echo "systemctl reload apache2"
  elif apt_is_installed lighttpd; then echo "systemctl reload lighttpd"
  else echo ":"
  fi
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-webserver-ssl.sh && echo OK`
Expected: `OK`

### Task 5.4: Update vhost templates with multi-name + new cert path

**Files:**
- Modify: `features/feature-webserver-ssl.sh`

- [ ] **Step 1: Update nginx cert paths**

Use `Edit` (the function is `_write_nginx_site_config`):

- Find: `ssl_certificate     /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/fullchain.pem;`
- Replace: `ssl_certificate     /etc/acme.sh/${primary}/fullchain.pem;`

- Find: `ssl_certificate_key /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/privkey.pem;`
- Replace: `ssl_certificate_key /etc/acme.sh/${primary}/privkey.pem;`

- [ ] **Step 2: Update nginx `server_name` directive**

In the same nginx template, find the line `server_name ${WEBSERVER_SERVER_NAME};` and change to `server_name ${primary} ${sans[*]};`. The Edit must respect that `sans` may be empty (bash word-splitting handles this).

- [ ] **Step 3: Update apache cert paths**

Find:
```
SSLCertificateFile      /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/fullchain.pem
SSLCertificateKeyFile   /etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/privkey.pem
```
Replace:
```
SSLCertificateFile      /etc/acme.sh/${primary}/fullchain.pem
SSLCertificateKeyFile   /etc/acme.sh/${primary}/privkey.pem
```

- [ ] **Step 4: Update apache `ServerName` + add `ServerAlias`**

Find `ServerName ${WEBSERVER_SERVER_NAME}`. Replace with:

```
ServerName ${primary}
ServerAlias ${sans[*]}
```

The `ServerAlias` line is harmless when sans is empty (Apache treats `ServerAlias` with no args as a no-op).

- [ ] **Step 5: Update lighttpd cert paths**

Find:
```
ssl.pemfile              = "/etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/fullchain.pem"
ssl.privkey              = "/etc/letsencrypt/live/${WEBSERVER_SERVER_NAME}/privkey.pem"
```
Replace:
```
ssl.pemfile              = "/etc/acme.sh/${primary}/fullchain.pem"
ssl.privkey              = "/etc/acme.sh/${primary}/privkey.pem"
```

- [ ] **Step 6: Add lighttpd multi-host regex helper**

The lighttpd template currently uses `$HTTP["host"] == "${WEBSERVER_SERVER_NAME}"`. With multi-name we need a regex. Insert this helper before `_write_lighttpd_ssl_config`:

```bash
# _lighttpd_hosts_regex <primary> [<san>...]
# Echoes a regex anchored "^(name1|name2|...)$" with regex-safe
# escaping. Dots are escaped; "*" is converted to ".*" so a wildcard
# entry like "*.example.com" becomes ".*\.example\.com".
_lighttpd_hosts_regex() {
  local -a parts=()
  local n esc
  for n in "$@"; do
    esc=$(printf '%s' "$n" | sed 's/\./\\./g; s/\*/.*/g')
    parts+=("$esc")
  done
  local IFS='|'
  echo "^(${parts[*]})\$"
}
```

Then in the lighttpd template body, replace `$HTTP["host"] == "${WEBSERVER_SERVER_NAME}"` with `$HTTP["host"] =~ "$(_lighttpd_hosts_regex "$primary" "${sans[@]}")"`.

- [ ] **Step 7: Update the install-body call sites to pass `primary` + `sans`**

In `do_install` and any other site-config caller, the vhost-rendering functions previously took `WEBSERVER_SERVER_NAME` implicitly. They now expect `primary` and `sans` to be set in scope. Find each call to `_write_nginx_site_config`, `_write_apache_vhost`, `_write_lighttpd_ssl_config`, and confirm the local variables `primary` and `sans` are defined before them. If not, add the parsing:

```bash
local -a NAMES primary sans
mapfile -t NAMES < <(cert_parse_names "$WEBSERVER_SERVER_NAME")
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
```

- [ ] **Step 8: Syntax-check**

Run: `bash -n features/feature-webserver-ssl.sh && echo OK`
Expected: `OK`

### Task 5.5: Rewrite `do_uninstall` to delegate to `cert_uninstall`

**Files:**
- Modify: `features/feature-webserver-ssl.sh`

- [ ] **Step 1: Replace the certbot revert block in `do_uninstall`**

In the current `do_uninstall` body, find the block that calls `_remove_cf_credentials` + `installer_apt_revert ... python3-certbot-dns-cloudflare` + `installer_apt_revert ... certbot`. Replace that block with:

```bash
  # Delegate cert lifecycle cleanup to lib/cert.sh.
  source lib/cert.sh && {
    local -a NAMES primary
    mapfile -t NAMES < <(cert_parse_names "$WEBSERVER_SERVER_NAME")
    primary="${NAMES[0]:-}"
    if [[ -n $primary ]]; then
      cert_uninstall "$primary"
    fi
  }
```

- [ ] **Step 2: Update the uninstall log message**

Find the final `log_warn` line about certs preserved at `/etc/letsencrypt`. Replace with:

```bash
log_warn "HTTPS / SSL uninstalled. acme.sh registry entry for the primary domain was removed; /etc/acme.sh/<name>/ deployed files were cleared. /opt/acme.sh/ is kept (other features may use it)."
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n features/feature-webserver-ssl.sh && echo OK`
Expected: `OK`

### Task 5.6: Bump `II_VERSION` 4 → 5

**Files:**
- Modify: `features/feature-webserver-ssl.sh`

- [ ] **Step 1: Edit the manifest**

Use `Edit` to change `II_VERSION="4"` to `II_VERSION="5"` in the manifest block.

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-webserver-ssl.sh && echo OK`
Expected: `OK`

### Task 5.7: Write `tests/test-webserver-ssl-integration.sh`

**Files:**
- Create: `tests/test-webserver-ssl-integration.sh`

- [ ] **Step 1: Write the file**

```bash
#!/bin/bash
# Tests for feature-webserver-ssl.sh's helpers: _reload_cmd_for_backend
# and the three vhost-template render paths (multi-name handling).

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPD=$(mktemp -d)
trap "rm -rf $TMPD" EXIT

# Stub apt_is_installed so we can flip backends per test.
apt_is_installed() { [[ ":$INSTALLED_BACKENDS:" == *":$1:"* ]]; }

# Source just the helper definitions from the feature file. We do this
# by sourcing the entire file with MODE=verify (which skips do_install)
# but the file's structure runs do_install at end — to avoid that we
# use a controlled subset:
source lib/cert.sh
# Inline the helpers we want to test (kept in sync with feature-webserver-ssl.sh).
# This pattern mirrors how test-menu-applicability.sh tests options.sh helpers.
_reload_cmd_for_backend() {
  if   apt_is_installed nginx;    then echo "systemctl reload nginx"
  elif apt_is_installed apache2;  then echo "systemctl reload apache2"
  elif apt_is_installed lighttpd; then echo "systemctl reload lighttpd"
  else echo ":"
  fi
}
_lighttpd_hosts_regex() {
  local -a parts=()
  local n esc
  for n in "$@"; do
    esc=$(printf '%s' "$n" | sed 's/\./\\./g; s/\*/.*/g')
    parts+=("$esc")
  done
  local IFS='|'
  echo "^(${parts[*]})\$"
}

# ---- _reload_cmd_for_backend tests ----
echo "=== Test: _reload_cmd_for_backend nginx ==="
INSTALLED_BACKENDS="nginx"
chkeq "nginx → systemctl reload nginx" "$(_reload_cmd_for_backend)" "systemctl reload nginx"

echo "=== Test: _reload_cmd_for_backend apache ==="
INSTALLED_BACKENDS="apache2"
chkeq "apache2 → systemctl reload apache2" "$(_reload_cmd_for_backend)" "systemctl reload apache2"

echo "=== Test: _reload_cmd_for_backend lighttpd ==="
INSTALLED_BACKENDS="lighttpd"
chkeq "lighttpd → systemctl reload lighttpd" "$(_reload_cmd_for_backend)" "systemctl reload lighttpd"

echo "=== Test: _reload_cmd_for_backend nothing ==="
INSTALLED_BACKENDS=""
chkeq "no backend → :" "$(_reload_cmd_for_backend)" ":"

# ---- _lighttpd_hosts_regex tests ----
echo "=== Test: _lighttpd_hosts_regex single ==="
chkeq "single name" "$(_lighttpd_hosts_regex example.com)" '^(example\.com)$'

echo "=== Test: _lighttpd_hosts_regex multi-SAN ==="
chkeq "multi-SAN" "$(_lighttpd_hosts_regex example.com www.example.com api.example.com)" '^(example\.com|www\.example\.com|api\.example\.com)$'

echo "=== Test: _lighttpd_hosts_regex wildcard ==="
chkeq "wildcard" "$(_lighttpd_hosts_regex example.com '*.example.com')" '^(example\.com|.*\.example\.com)$'

# ---- nginx server_name directive composition ----
echo "=== Test: nginx server_name composition ==="
NAMES=( example.com www.example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
expected="server_name example.com www.example.com;"
actual=$(printf "server_name %s %s;\n" "$primary" "${sans[*]}")
chkeq "multi-name server_name" "$actual" "$expected"

NAMES=( example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
actual=$(printf "server_name %s %s;\n" "$primary" "${sans[*]}")
chkeq "single-name server_name" "$actual" "server_name example.com ;"

# ---- apache ServerName + ServerAlias composition ----
echo "=== Test: apache ServerName + ServerAlias composition ==="
NAMES=( example.com www.example.com api.example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
{
  printf "ServerName %s\n" "$primary"
  printf "ServerAlias %s\n" "${sans[*]}"
} > "$TMPD/apache.conf"
grep -q "^ServerName example.com$" "$TMPD/apache.conf"
chkrc "ServerName written" $? 0
grep -q "^ServerAlias www.example.com api.example.com$" "$TMPD/apache.conf"
chkrc "ServerAlias written with all sans" $? 0

echo "=== Done ==="
```

- [ ] **Step 2: Make executable + run**

Run:
```
chmod +x tests/test-webserver-ssl-integration.sh
bash tests/test-webserver-ssl-integration.sh 2>&1 | tail -30
```
Expected: all OK.

### Task 5.8: Run full suite + commit Phase 5

- [ ] **Step 1: Bump VERSION to 2.9.11**

Write `2.9.11\n` to `VERSION`.

- [ ] **Step 2: Full parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: No-masked-FAIL check across all tests**

Run: `for t in tests/test-*.sh; do bash "$t" 2>&1 | grep -E "^  FAIL" && echo "FAIL in $t"; done | head -10`
Expected: empty output.

- [ ] **Step 4: Commit + push**

```bash
git add VERSION features/feature-webserver-ssl.sh tests/test-webserver-ssl-integration.sh
git commit -F- <<'MSG'
feature-webserver-ssl: switch to acme.sh + multi-name + wildcard

Phase 5. Refactors feature-webserver-ssl.sh:
- Delete _CERTBOT_ENV, CLOUDFLARE_CREDS_FILE, _write_cf_credentials,
  _remove_cf_credentials, _build_certonly_args (~130 LOC).
- Add _reload_cmd_for_backend helper (~10 LOC).
- Add _lighttpd_hosts_regex helper for multi-name regex.
- Rewrite _obtain_cert to parse comma-delimited WEBSERVER_SERVER_NAME,
  validate shape, strip wildcards when method=http (warn-per-stripped,
  error only if all stripped), and delegate to lib/cert.sh:
    cert_install_acme_sh → cert_issue → cert_install_to_paths → cert_renew_setup.
- Vhost templates updated:
    nginx: server_name multi-name; cert paths /etc/acme.sh/<primary>/.
    apache: ServerName + ServerAlias; cert paths /etc/acme.sh/<primary>/.
    lighttpd: $HTTP["host"] =~ multi-name regex; cert paths /etc/acme.sh/<primary>/.
- do_uninstall delegates to cert_uninstall <primary>.
- II_VERSION 4 → 5.

tests/test-webserver-ssl-integration.sh (new, ~120 lines) covers
_reload_cmd_for_backend (4 cases), _lighttpd_hosts_regex (3 cases),
and per-backend multi-name vhost composition (5 cases).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

---

## Phase 6 — `feature-caddy.sh` multi-name + Caddyfile updates (→ VERSION 2.9.12)

Caddy doesn't use lib/cert.sh — it has its own ACME client. We update Caddyfile templates for multi-name site blocks, the self-signed fallback cert to cover multi-SAN, and the strip-and-warn handling for wildcards (which Caddy can't issue without the deferred DNS plugin).

### Task 6.1: Add multi-name parsing + wildcard strip to `feature-caddy.sh`

**Files:**
- Modify: `features/feature-caddy.sh`

- [ ] **Step 1: Insert parsing block near the top of the install body**

Use `Edit` to insert just after the existing `WEBSERVER_SERVER_NAME` fallback block (around line 78-81 of the current file):

```bash
# Parse comma-delimited WEBSERVER_SERVER_NAME for multi-name support.
# lib/cert.sh provides cert_parse_names / cert_validate_names /
# cert_strip_wildcards / cert_require_nonempty — same parsing as
# feature-webserver-ssl.sh.
source lib/cert.sh || { log_fail "lib/cert.sh failed to source"; exit 1; }

local -a NAMES
mapfile -t NAMES < <(cert_parse_names "$WEBSERVER_SERVER_NAME")
cert_validate_names "${NAMES[@]}" || exit $?

# Caddy backend: strip wildcards always (the caddy-dns/cloudflare
# plugin is not installed by this feature; see spec open follow-ups).
mapfile -t NAMES < <(cert_strip_wildcards \
  "Caddy wildcard support not currently available (requires caddy add-package + caddy-dns/cloudflare; deferred to a future feature-caddy update)" \
  "${NAMES[@]}")
cert_require_nonempty "${NAMES[@]}" || exit $?

primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
```

(`local -a` outside a function is invalid in some shells; the existing feature-caddy.sh runs code at file scope, so use `declare -a` instead of `local -a`.)

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-caddy.sh && echo OK`
Expected: `OK`

### Task 6.2: Update Caddyfile templates for multi-name site blocks

**Files:**
- Modify: `features/feature-caddy.sh`

- [ ] **Step 1: Render the multi-name site block prefix**

There are three Caddyfile templates in the file: `redirect-all`, `redirect-name`, `deny-http`. Each starts with `${WEBSERVER_SERVER_NAME} {`. Replace with a rendered prefix.

Define a helper near the top of the install body (after the parsing block):

```bash
# _caddy_site_block_names — echo a Caddy-compatible site-block name
# list. Caddy accepts space-separated OR comma-separated names; we use
# space-separated for clarity. Returns just $primary if no SANs.
_caddy_site_block_names() {
  if (( ${#sans[@]} == 0 )); then
    echo "$primary"
  else
    echo "$primary ${sans[*]}"
  fi
}
```

Then in each Caddyfile template, replace `${WEBSERVER_SERVER_NAME} {` with `$(_caddy_site_block_names) {`. Three substitutions total.

- [ ] **Step 2: Update `@canonical host` matcher**

In the `redirect-name` policy template, find `@canonical host ${WEBSERVER_SERVER_NAME}`. Replace with `@canonical host $primary ${sans[*]}` (Caddy's `host` matcher accepts space-separated values; matches if any).

- [ ] **Step 3: Syntax-check**

Run: `bash -n features/feature-caddy.sh && echo OK`
Expected: `OK`

### Task 6.3: Update self-signed fallback cert for multi-SAN

**Files:**
- Modify: `features/feature-caddy.sh`

- [ ] **Step 1: Find the openssl cert-generation block**

Run: `grep -n "subjectAltName\|openssl req" features/feature-caddy.sh`

- [ ] **Step 2: Replace the subjectAltName line**

The current line is:
```
-addext "subjectAltName=DNS:${WEBSERVER_SERVER_NAME}"
```

Build the SAN list dynamically. Insert this just before the `openssl req` call:

```bash
# Build a SAN list covering primary + all sans. Wildcards have already
# been stripped above; everything remaining is a regular hostname.
local san_list="DNS:$primary"
local s
for s in "${sans[@]}"; do
  san_list+=",DNS:$s"
done
```

Then replace:
```
-addext "subjectAltName=DNS:${WEBSERVER_SERVER_NAME}"
```
With:
```
-addext "subjectAltName=$san_list"
```

Also update the `-subj "/CN=${WEBSERVER_SERVER_NAME}"` to `-subj "/CN=$primary"`.

- [ ] **Step 3: Update the log line**

The `log_info "Generating self-signed fallback cert ... CN=$WEBSERVER_SERVER_NAME"` line should become:

```bash
log_info "Generating self-signed fallback cert for unmatched-SNI HTTPS (CN=$primary, SANs=$san_list)."
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n features/feature-caddy.sh && echo OK`
Expected: `OK`

### Task 6.4: Bump `II_VERSION` on `feature-caddy.sh`

**Files:**
- Modify: `features/feature-caddy.sh`

- [ ] **Step 1: Inspect current value**

Run: `grep -n "^II_VERSION=" features/feature-caddy.sh`

- [ ] **Step 2: Increment**

Use `Edit` to bump `II_VERSION="N"` to `II_VERSION="N+1"` (e.g. from 1 to 2 if it's currently 1).

### Task 6.5: Write `tests/test-caddy-integration.sh`

**Files:**
- Create: `tests/test-caddy-integration.sh`

- [ ] **Step 1: Write the file**

```bash
#!/bin/bash
# Tests for feature-caddy.sh's multi-name handling — site-block
# composition, wildcard strip-and-warn, multi-SAN self-signed fallback,
# @canonical host matcher.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/cert.sh

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPD=$(mktemp -d)
trap "rm -rf $TMPD" EXIT

LOG_FILE="$TMPD/log.txt"
log_info() { echo "INFO $*" >> "$LOG_FILE"; }
log_warn() { echo "WARN $*" >> "$LOG_FILE"; }
log_fail() { echo "FAIL $*" >> "$LOG_FILE"; }
_reset_log() { : > "$LOG_FILE"; }

# Inline copies of the helpers from feature-caddy.sh — kept in sync.
_caddy_site_block_names() {
  if (( ${#sans[@]} == 0 )); then
    echo "$primary"
  else
    echo "$primary ${sans[*]}"
  fi
}

# ---- Test 1: single-name site block ----
echo "=== Test 1: single-name site block ==="
declare -a NAMES sans
NAMES=( example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
chkeq "single name" "$(_caddy_site_block_names)" "example.com"

# ---- Test 2: multi-name site block ----
echo "=== Test 2: multi-name site block ==="
NAMES=( example.com www.example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
chkeq "multi-name" "$(_caddy_site_block_names)" "example.com www.example.com"

# ---- Test 3: wildcard mixed — stripped with warn ----
echo "=== Test 3: wildcard mixed — strip + warn ==="
_reset_log
mapfile -t NAMES < <(cert_parse_names "example.com, *.example.com")
mapfile -t NAMES < <(cert_strip_wildcards \
  "Caddy wildcard support not currently available (requires caddy add-package + caddy-dns/cloudflare; deferred to a future feature-caddy update)" \
  "${NAMES[@]}")
chkeq "wildcard stripped" "$(printf '%s|' "${NAMES[@]}")" "example.com|"
grep -q "Dropping wildcard '\*.example.com'" "$LOG_FILE"
chkrc "log_warn names the stripped wildcard" $? 0
grep -q "Caddy wildcard support not currently available" "$LOG_FILE"
chkrc "log_warn names the reason" $? 0

# ---- Test 4: all wildcards — empty result, error ----
echo "=== Test 4: all wildcards → empty + error ==="
_reset_log
mapfile -t NAMES < <(cert_parse_names "*.example.com, *.api.example.com")
mapfile -t NAMES < <(cert_strip_wildcards "test reason" "${NAMES[@]}")
chkeq "empty result" "${#NAMES[@]}" "0"
cert_require_nonempty "${NAMES[@]}"
chkrc "require_nonempty fires error" $? 1
grep -q "^FAIL" "$LOG_FILE"
chkrc "log_fail emitted" $? 0

# ---- Test 5: multi-SAN self-signed subjectAltName composition ----
echo "=== Test 5: multi-SAN self-signed SAN composition ==="
NAMES=( example.com www.example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
san_list="DNS:$primary"
for s in "${sans[@]}"; do san_list+=",DNS:$s"; done
chkeq "subjectAltName list" "$san_list" "DNS:example.com,DNS:www.example.com"

# ---- Test 6: @canonical host matcher composition ----
echo "=== Test 6: @canonical host matcher ==="
NAMES=( example.com www.example.com )
primary="${NAMES[0]}"
sans=("${NAMES[@]:1}")
chkeq "canonical host list" "@canonical host $primary ${sans[*]}" "@canonical host example.com www.example.com"

echo "=== Done ==="
```

- [ ] **Step 2: Make executable + run**

Run:
```
chmod +x tests/test-caddy-integration.sh
bash tests/test-caddy-integration.sh 2>&1 | tail -20
```
Expected: all OK.

### Task 6.6: Run full suite + commit Phase 6

- [ ] **Step 1: Bump VERSION to 2.9.12**

Write `2.9.12\n` to `VERSION`.

- [ ] **Step 2: Full parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: No-masked-FAIL check**

Run: `for t in tests/test-*.sh; do bash "$t" 2>&1 | grep -E "^  FAIL" && echo "FAIL in $t"; done | head -10`
Expected: empty.

- [ ] **Step 4: Commit + push**

```bash
git add VERSION features/feature-caddy.sh tests/test-caddy-integration.sh
git commit -F- <<'MSG'
feature-caddy: multi-name Caddyfile + wildcard strip-and-warn

Phase 6. Caddy doesn't use lib/cert.sh (it has its own ACME client),
but it benefits from the same comma-delimited WEBSERVER_SERVER_NAME
parsing.

Changes to features/feature-caddy.sh:
- Source lib/cert.sh for cert_parse_names / cert_validate_names /
  cert_strip_wildcards / cert_require_nonempty.
- After parsing + shape validation: unconditionally strip wildcards
  (Caddy wildcard support requires the caddy-dns/cloudflare plugin,
  deferred). Error if every name was a wildcard.
- New _caddy_site_block_names helper composes the multi-name prefix
  for Caddyfile site blocks (space-separated, Caddy's preferred form).
- All three policy templates (redirect-all, redirect-name, deny-http)
  now use the multi-name prefix.
- @canonical host matcher (redirect-name policy) lists primary + sans.
- Self-signed fallback cert: CN=$primary, subjectAltName covers all
  surviving names (DNS:primary,DNS:san1,DNS:san2...).
- II_VERSION bumped.

tests/test-caddy-integration.sh (new, ~100 lines): 6 cases covering
single-name, multi-name, wildcard-stripped-with-warn, all-wildcards-
empty-error, multi-SAN subjectAltName composition, @canonical host
matcher composition.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

---

## Phase 7 — Docs + MINOR landing (→ VERSION 2.10.0)

Final phase: README + config doc updates + the MINOR bump that marks feature completion.

### Task 7.1: Update `config/webserver.config` WEBSERVER_SERVER_NAME comment

**Files:**
- Modify: `config/webserver.config`

- [ ] **Step 1: Find the existing comment**

Run: `grep -n "WEBSERVER_SERVER_NAME" config/webserver.config`

- [ ] **Step 2: Replace the comment block**

Use `Edit` to update the comment + value lines. The new block:

```bash
# Vhost name(s). Single hostname, or comma-separated list for multi-SAN
# certs. First entry is the primary (cert path is keyed on it).
# Wildcards (*.example.com) require WEBSERVER_SSL_METHOD=dns-cloudflare —
# Let's Encrypt rejects wildcards via HTTP-01. Wildcards on the Caddy
# backend are NOT supported today (requires Caddy 2.7+ caddy-dns/cloudflare
# plugin — deferred to a future feature-caddy update). On non-supporting
# backends, wildcards are stripped with a warning at install time; the
# install fails only if every name was a wildcard.
# Examples:
#   example.com
#   example.com, www.example.com
#   example.com, *.example.com    (acme.sh backends with dns-cloudflare)
WEBSERVER_SERVER_NAME=""
```

### Task 7.2: Mirror the comment in `overrides/configuration.override.example`

**Files:**
- Modify: `overrides/configuration.override.example`

- [ ] **Step 1: Find the existing WEBSERVER_SERVER_NAME entry**

Run: `grep -n "WEBSERVER_SERVER_NAME" overrides/configuration.override.example`

- [ ] **Step 2: Replace the inline comment**

The existing entry is something like:
```bash
#WEBSERVER_SERVER_NAME=""                   # vhost name; blank = the Pi's hostname at install time
```

Replace the inline comment with a brief reference to the full doc + a clear syntax hint:

```bash
#WEBSERVER_SERVER_NAME=""                   # vhost name(s); single, OR comma-separated list (first = primary).
                                             # Wildcards (*.example.com) require WEBSERVER_SSL_METHOD=dns-cloudflare.
                                             # Caddy backend: wildcards stripped with warn (plugin deferred).
                                             # See config/webserver.config for full docs.
```

### Task 7.3: Update `README.md` SSL/HTTPS section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the SSL/HTTPS section**

Run: `grep -n "webserver-ssl\|webserver-ssl\|HTTPS\|certbot\|Let's Encrypt" README.md | head -10`

- [ ] **Step 2: Replace certbot references with acme.sh**

In the SSL/HTTPS section, look for sentences mentioning "certbot" and replace with "acme.sh". Specifically:
- "Issues a Let's Encrypt cert via certbot" → "Issues a Let's Encrypt cert via acme.sh"
- "/etc/letsencrypt/live/<name>/" → "/etc/acme.sh/<name>/"
- Any explicit `python3-certbot-dns-cloudflare` mention → drop

- [ ] **Step 3: Document multi-name syntax**

Find the row in the feature catalog table for `webserver-ssl` (or add it if missing). Update the description to mention:
- acme.sh (not certbot)
- Comma-delimited WEBSERVER_SERVER_NAME for multi-SAN
- Wildcard support requires dns-cloudflare method

### Task 7.4: Final tests + MINOR-bump VERSION + commit

- [ ] **Step 1: MINOR-bump VERSION**

Write `2.10.0\n` to `VERSION`.

- [ ] **Step 2: Full parallel test run**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `Total: N test(s), 0 failed`.

- [ ] **Step 3: No-masked-FAIL sweep**

Run: `for t in tests/test-*.sh; do bash "$t" 2>&1 | grep -E "^  FAIL" && echo "FAIL in $t"; done | head -10`
Expected: empty.

- [ ] **Step 4: Commit + push the landing**

```bash
git add VERSION config/webserver.config overrides/configuration.override.example README.md
git commit -F- <<'MSG'
acme.sh: docs + MINOR bump (2.9.x → 2.10.0) — feature landing

Final landing commit for the acme.sh switch + multi-domain + wildcard
work. Phases 0-6 shipped:
  - Phase 0: lib/cert.sh foundation (parse, validate, strip, require)
  - Phase 1: cert_install_acme_sh + cert_uninstall
  - Phase 2: cert_issue + cert_install_to_paths + creds-file write
  - Phase 3: cert_renew_setup + systemd templates
  - Phase 4: cert_verify (5-check health)
  - Phase 5: feature-webserver-ssl refactor + integration tests
  - Phase 6: feature-caddy multi-name + integration tests

config/webserver.config: WEBSERVER_SERVER_NAME comment block now
documents comma-delimited syntax, wildcard rules per method, and the
Caddy backend deferral.

overrides/configuration.override.example: matching inline comment.

README.md: SSL/HTTPS section updated to mention acme.sh instead of
certbot; new comma-delimited WEBSERVER_SERVER_NAME syntax documented;
cert path /etc/acme.sh/<primary>/ called out.

MINOR bump per the project's feature-complete-landing policy.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
git push
```

- [ ] **Step 5: Confirm final state**

Run: `git log --oneline -10 origin/acme-sh`
Expected: shows the 8 phase commits + the plan-itself commit.

Run: `cat VERSION`
Expected: `2.10.0`.

---

## Spec self-review (done before plan publish)

- **Spec coverage:** Every section of the spec (Phase 0 foundation, install lifecycle, issuance, renewal timer, verify, feature-webserver-ssl integration, feature-caddy integration, multi-domain + wildcard support, validation/strip gate, editable-key documentation, testing strategy, VERSION policy, README updates) maps to at least one task above.
- **No placeholders:** Every code block is concrete; no TBD / TODO / "implement here". Per-phase commit messages are pre-written.
- **Type consistency:** `cert_install_acme_sh` takes no positional args (reads `CERT_EMAIL` from env) — used consistently across Phase 1, Phase 5. `cert_issue <primary> <method> [<san>...]` signature matches between lib definition (Phase 2) and feature delegation (Phase 5). `cert_install_to_paths <name> <fullchain> <key> <reloadcmd>` is identical between lib and feature. Test-hook env vars (`ACME_SH_HOME_OVERRIDE`, `SYSTEMD_UNIT_DEST_OVERRIDE`, `CERT_DEPLOY_BASE_OVERRIDE`, `CERT_SKIP_REAL_NETWORK`) used consistently across all relevant phases.
- **Phase ordering:** Phase 0 (parse/validate/strip/require) must land before Phase 5 (feature delegates to them). Phase 1 (acme.sh install) before Phase 2 (cert_issue calls _cert_acme_home). Phase 3 (renewal templates) before Phase 5 (feature calls cert_renew_setup). Phase 4 (cert_verify) is freestanding — used by `--verify` dispatcher but not blocking install. All dependencies satisfied by the linear phase order.
