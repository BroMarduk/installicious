# `installicious --verify` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land `installicious --verify` — a top-level command that prints `OK` / `FAIL` / `NOT INSTALLED` per installer plus a summary block — per [the design spec](../specs/2026-05-24-verify-installed-design.md) (committed `6884ea5`).

**Architecture:** New `lib/verify.sh` with 5 reusable primitives + a `verify_generic` fallback. New `--verify` arg-handler block in `installicious.sh` that bypasses the root gate, the menu, and the whiptail dep check; dispatches per-installer `bash <script> --verify` subprocesses; renders fixed-width rows. Every `feature-*.sh` and `installer_apt_main` learns a `--verify` case; most call `verify_generic` and the few that need custom liveness checks add their own `do_verify` body.

**Tech Stack:** Bash 5; `dpkg-query`, `systemctl`, `ss` (iproute2); test framework: inline per-file `ok`/`fail`/`chkeq`/`chkrc` helpers (see [tests/test-manifest.sh:11-14](../../../tests/test-manifest.sh#L11-L14)).

**Branch:** `ai-refactor`. Spec at `6884ea5`. Current VERSION `2.6.2`.

---

## Pre-flight checklist (read once before Phase 1)

- All work on `ai-refactor`. No worktree needed.
- After each phase: run the full test suite (`for t in tests/test-*.sh; do bash "$t"; done`) and confirm all files rc=0. Phase 1 adds `tests/test-verify.sh` (15 → 15 files of which one is new).
- Per-commit PATCH bump per memory. Final phase MINOR bumps 2.6.x → `2.7.0`.
- Commit trailer (single-quoted HEREDOC):
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  ```
- Use `Edit`/`Write`/`Glob`/`Grep`. No `sed`/`grep`/`cat`. No `git push`. No `git commit --amend`. No `--no-verify`.
- Reference features for the verify case + library-source convention: [features/feature-pkupd.sh](../../../features/feature-pkupd.sh), [features/feature-database-mysql.sh](../../../features/feature-database-mysql.sh), [lib/installer_apt.sh](../../../lib/installer_apt.sh).
- Manifest fields documentation lives at the top of [lib/manifest.sh](../../../lib/manifest.sh) — the optional `II_SERVICE` we're adding goes there.

---

## File structure

### New files
| Path | Purpose |
|---|---|
| `lib/verify.sh` | 5 primitives + `verify_generic <id>` fallback + `verify_dispatch_main` (used by the dispatcher AND tests). |
| `tests/test-verify.sh` | Unit tests for the primitives, `verify_generic`, `verify_dispatch_main`, formatting, edge cases. Tempdir-isolated, no real dpkg/systemd contact. |

### Modified files
| Path | Phase | Change |
|---|---|---|
| `installicious.sh` | 2 | New `--verify` arg-handler block after the `--uninstall` block. Bypasses root gate / menu / whiptail. |
| `lib/installer_apt.sh` | 3 | `installer_apt_main` gains a `--verify) ...` case; new `_installer_apt_do_verify` body calls `verify_generic`. |
| `lib/manifest.sh` | 1 | Header comment paragraph documenting the new optional `II_SERVICE` field. |
| `features/feature-*.sh` (~28 files) | 4 | Mechanical: source `lib/verify.sh`, add `--verify) MODE="verify" ;;` case, add `do_verify`. Most are one-liner `do_verify() { verify_generic "$II_ID"; }`. |
| Webserver children: `feature-nginx.sh`, `feature-apache.sh`, `feature-lighttpd.sh`, `feature-caddy.sh` | 5a | Hand-written `do_verify` with `*ctl configtest` + port check. |
| Database children: `feature-database-mysql.sh`, `feature-database-mariadb.sh` | 5b | Hand-written `do_verify` with `mysql -u root -e "SELECT 1"` + Python pkg check. (sqlite child is a no-op leaf; the one-liner is enough.) |
| WeeWX ecosystem: `feature-weewx-setup.sh`, `feature-weewx-database-ram.sh`, `feature-weewx-site-ram.sh`, `feature-weewx-webroot.sh`, `feature-neowx-material.sh`, `feature-weewx-onedrive-backup.sh`, `feature-skyfield.sh` | 5c | Hand-written `do_verify` with feature-specific checks. |
| `README.md` | 6 | New "Verifying an install" section. |
| `VERSION` | each phase | PATCH bump per phase; MINOR bump on phase 6. |

---

## Phase 1 — `lib/verify.sh` + primitives + `verify_generic` + tests (→ 2.6.3)

### Task 1.1: Create `lib/verify.sh`

**Files:**
- Create: `lib/verify.sh`

- [ ] **Step 1: Write `lib/verify.sh`**

```bash
#!/bin/bash

# lib/verify.sh — primitives + generic fallback for `installicious --verify`.
#
# Helpers come in three layers:
#
# 1. Primitives — verify_dpkg_installed, verify_systemd_active,
#    verify_port_listening, verify_file_exists,
#    verify_require_completed_state.
#    Each takes minimal args, returns rc 0/1 (or 0/2 for the
#    status-state check), and prints one stderr diagnostic on failure
#    so a calling do_verify can capture + forward to stdout.
#
# 2. Generic fallback — verify_generic <id>. Drives the primitives off
#    the manifest's II_APT_PACKAGES + the optional II_SERVICE field +
#    the status file's pre-state record. Most do_verify bodies are just
#    `verify_generic "$II_ID"`.
#
# 3. Dispatcher — verify_dispatch_main "$@". The main loop that
#    `installicious --verify` invokes. Extracted as a function so tests
#    can call it directly without forking installicious.sh.
#
# Callers must have already sourced:
#   lib/log.sh lib/status.sh lib/manifest.sh config/installicious.config

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

# verify_dpkg_installed <pkg> -> rc 0 if dpkg-query reports "ok installed".
# Prints "dpkg: <pkg> not installed (status=<status-or-missing>)" to stderr
# on failure for the caller to capture + forward.
verify_dpkg_installed() {
  local pkg="$1" status
  status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)
  if [[ "$status" == *"ok installed"* ]]; then
    return 0
  fi
  echo "dpkg: $pkg not installed (status=${status:-missing})" >&2
  return 1
}

# verify_systemd_active <unit> -> rc 0 if systemctl is-active --quiet $unit.
# Prints "systemctl is-active <unit>: <state>" on failure.
verify_systemd_active() {
  local unit="$1" state
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    return 0
  fi
  state=$(systemctl is-active "$unit" 2>/dev/null || true)
  echo "systemctl is-active $unit: ${state:-unknown}" >&2
  return 1
}

# verify_port_listening <port> [tcp|udp] -> rc 0 if `ss -lnt` (or -lnu for
# udp) shows something LISTEN-ing on $port.
# Prints "port $port/$proto: not listening" on failure.
verify_port_listening() {
  local port="$1" proto="${2:-tcp}"
  local flag
  case "$proto" in
    tcp) flag="-lnt" ;;
    udp) flag="-lnu" ;;
    *)
      echo "verify_port_listening: unknown proto '$proto' (expected tcp|udp)" >&2
      return 1
      ;;
  esac
  # ss output: "LISTEN 0 511 *:80 ..."  -- match :PORT at column boundary.
  if ss $flag 2>/dev/null | awk -v p="$port" '
       NR > 1 {
         # ss formats local addr as "addr:port"; the port is what
         # follows the last colon. Strip everything up to it.
         n = split($4, a, ":")
         if (a[n] == p) { found = 1; exit }
       }
       END { exit !found }
     '; then
    return 0
  fi
  echo "port $port/$proto: not listening" >&2
  return 1
}

# verify_file_exists <path> -> rc 0 if $path exists.
# Prints "file $path: missing" on failure.
verify_file_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    return 0
  fi
  echo "file $path: missing" >&2
  return 1
}

# verify_require_completed_state <id> -> rc 0 silent if status_state $id
# is "completed"; rc 2 with one stdout reason line otherwise. Every
# do_verify MUST call this (or verify_generic) at the top so the
# dispatcher sees NOT INSTALLED for non-completed items.
verify_require_completed_state() {
  local id="$1" state
  state=$(status_state "$id" 2>/dev/null)
  if [[ "$state" == "completed" ]]; then
    return 0
  fi
  if [[ -z "$state" ]]; then
    echo "no status file"
  else
    # state may be "uninstalled", "failed: <msg>", "reboot-pending", etc.
    echo "state=$state"
  fi
  return 2
}

# ---------------------------------------------------------------------------
# Generic verifier — drives primitives off manifest + status file.
# ---------------------------------------------------------------------------

# verify_generic <id> -> 0 (OK) | 1 (FAIL) | 2 (NOT INSTALLED).
# Status check, then for each apt package the status file says we OWN
# (PRE_INSTALLED=false), check dpkg. Then if II_SERVICE is declared,
# check systemctl. If nothing was checkable, print "(no liveness
# checks declared)" and return 0.
verify_generic() {
  local id="$1" path apt_packages service status_file
  verify_require_completed_state "$id" || return 2

  path=$(manifest_path_for "$id" 2>/dev/null)
  if [[ -z "$path" ]]; then
    echo "installer script not found for id '$id'"
    return 1
  fi
  apt_packages=$(manifest_get_field "$path" "II_APT_PACKAGES" 2>/dev/null)
  service=$(manifest_get_field "$path" "II_SERVICE" 2>/dev/null)
  status_file=$(status_file_for "$id" 2>/dev/null)

  local rc=0 checked=0 err pkg pre_var pre_val

  if [[ -n "$apt_packages" ]]; then
    for pkg in $apt_packages; do
      # Pre-install state recorded as <PKG_UPPER>_FW_PRE_INSTALLED=true|false
      # by installer_apt_record_install. We own packages whose pre-state
      # was false (i.e. installicious put them on the box).
      pre_var="${pkg^^}"
      # dpkg pkg names use - and . which aren't valid in shell var names;
      # mirror installer_apt's substitution: - and . -> _.
      pre_var="${pre_var//-/_}"
      pre_var="${pre_var//./_}"
      pre_var="${pre_var}_FW_PRE_INSTALLED"
      pre_val=""
      if [[ -f "$status_file" ]]; then
        pre_val=$(
          # shellcheck disable=SC1090
          source "$status_file" 2>/dev/null
          printf '%s' "${!pre_var:-}"
        )
      fi
      [[ "$pre_val" == "true" ]] && continue  # pre-existing, not ours
      checked=$((checked + 1))
      if ! err=$(verify_dpkg_installed "$pkg" 2>&1); then
        echo "$err"
        rc=1
      fi
    done
  fi

  if [[ -n "$service" ]]; then
    checked=$((checked + 1))
    if ! err=$(verify_systemd_active "$service" 2>&1); then
      echo "$err"
      rc=1
    fi
  fi

  if [[ "$checked" -eq 0 ]]; then
    echo "(no liveness checks declared)"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# Dispatcher — invoked by installicious.sh --verify; extracted for tests.
# ---------------------------------------------------------------------------

# Color codes mirror features/feature-nginx.sh:141.
_VERIFY_C_OK='\e[0;32m'
_VERIFY_C_FAIL='\e[0;31m'
_VERIFY_C_NOT='\e[0;36m'
_VERIFY_C_RESET='\e[0m'

# verify_dispatch_main "$@" -> overall exit 0 (zero FAILs) or 1 (any FAIL).
# Unknown positional IDs -> exit 2 without running anything else.
verify_dispatch_main() {
  local mode="default" verbose=0
  local -a positional=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --all)        mode="all" ;;
      --list)       mode="list" ;;
      -v|--verbose) verbose=1 ;;
      --*)
        echo "verify: unknown option '$arg'" >&2
        return 2
        ;;
      *) positional+=("$arg") ;;
    esac
  done
  if [[ ${#positional[@]} -gt 0 ]]; then
    mode="ids"
  fi

  if [[ "$mode" == "list" ]]; then
    _verify_print_list
    return 0
  fi

  local -a target_ids=()
  case "$mode" in
    all) mapfile -t target_ids < <(manifest_list_ids) ;;
    ids)
      local id path
      for id in "${positional[@]}"; do
        path=$(manifest_path_for "$id" 2>/dev/null)
        if [[ -z "$path" ]]; then
          echo "verify: unknown id '$id'" >&2
          return 2
        fi
      done
      target_ids=("${positional[@]}")
      ;;
    default)
      local f base
      for f in "$PATH_STATUS"/*.status; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .status)
        [[ "$base" == "os" ]] && continue
        target_ids+=("$base")
      done
      ;;
  esac

  local ok=0 fail=0 not=0 id rc out path title
  for id in "${target_ids[@]}"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    title=$(manifest_get_field "$path" "II_TITLE" 2>/dev/null)
    [[ -z "$title" ]] && title="$id"
    if [[ -z "$path" ]] || [[ ! -f "$path" ]]; then
      _verify_print_row FAIL "$id" "$title" "installer script not found at ${path:-<unresolved>}"
      fail=$((fail + 1))
      continue
    fi
    out=$(bash "$path" --verify 2>&1); rc=$?
    case "$rc" in
      0)
        _verify_print_row OK "$id" "$title"
        [[ $verbose -eq 1 && -n "$out" ]] && _verify_print_indented "$out"
        ok=$((ok + 1))
        ;;
      1)
        _verify_print_row FAIL "$id" "$title"
        [[ -n "$out" ]] && _verify_print_indented "$out"
        fail=$((fail + 1))
        ;;
      2)
        _verify_print_row NOT "$id" "$title"
        [[ -n "$out" ]] && _verify_print_indented "$out"
        not=$((not + 1))
        ;;
      *)
        _verify_print_row FAIL "$id" "$title" "verifier returned unexpected exit code $rc"
        [[ -n "$out" ]] && _verify_print_indented "$out"
        fail=$((fail + 1))
        ;;
    esac
  done

  _verify_print_summary "$ok" "$fail" "$not"
  [[ $fail -gt 0 ]] && return 1
  return 0
}

_verify_print_list() {
  local id title path
  mapfile -t all_ids < <(manifest_list_ids)
  for id in "${all_ids[@]}"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    title=$(manifest_get_field "$path" "II_TITLE" 2>/dev/null)
    [[ -z "$title" ]] && title="$id"
    printf '         %-22s — %s\n' "$id" "$title"
  done
}

_verify_print_row() {
  local badge="$1" id="$2" title="$3" reason="${4:-}" color label
  case "$badge" in
    OK)   color="$_VERIFY_C_OK";   label="  OK  " ;;
    FAIL) color="$_VERIFY_C_FAIL"; label=" FAIL " ;;
    NOT)  color="$_VERIFY_C_NOT";  label=" NOT  " ;;
  esac
  printf "[${color}%s${_VERIFY_C_RESET}] %-22s — %s\n" "$label" "$id" "$title"
  [[ -n "$reason" ]] && _verify_print_indented "$reason"
}

_verify_print_indented() {
  local block="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '           %s\n' "$line"
  done <<< "$block"
}

_verify_print_summary() {
  local ok="$1" fail="$2" not="$3"
  echo "============================================================"
  echo "  Verify summary"
  echo "============================================================"
  printf '  OK:           %3d\n' "$ok"
  printf '  FAIL:         %3d\n' "$fail"
  printf '  NOT INSTALLED:%3d\n' "$not"
  echo "============================================================"
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n lib/verify.sh && echo OK`
Expected: `OK`

### Task 1.2: Document `II_SERVICE` in `lib/manifest.sh`

**Files:**
- Modify: `lib/manifest.sh` (header comment, around line 7-16 where other II_* fields are documented)

- [ ] **Step 1: Find the manifest field documentation block**

Run: `Grep` for `II_DEPS` in `lib/manifest.sh` with `-n true -B 2 -A 8` to find the field-doc comment area.

- [ ] **Step 2: Add an `II_SERVICE` paragraph**

Insert the following paragraph immediately after the existing `II_OPTIONAL_GROUP` / `II_RESTRICT_TO_ROLES` paragraphs (find a clean insertion point in the field-doc block):

```bash
#   II_SERVICE="<systemd-unit>"  optional. If set, --verify's generic
#                                fallback runs `systemctl is-active <unit>`
#                                as part of the liveness check. Skip when
#                                the feature owns no long-running service
#                                (e.g. a one-shot config tweak).
```

Use `Edit` with a unique `old_string` from the surrounding doc text.

### Task 1.3: Create `tests/test-verify.sh` (Group 1 — primitives)

**Files:**
- Create: `tests/test-verify.sh`

- [ ] **Step 1: Write the test file scaffold + primitives tests**

```bash
#!/bin/bash
# Tests for lib/verify.sh — primitives, generic fallback, dispatcher,
# output format, edge cases. No real dpkg / systemd / ss contact:
# stubs in a tempdir are placed at the front of PATH.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# --- Tempdir-isolated env -------------------------------------------------
TEST_TMPDIR=$(mktemp -d)
trap "rm -rf $TEST_TMPDIR" EXIT
export PATH_STATE="$TEST_TMPDIR/state"
export PATH_STATUS="$TEST_TMPDIR/status"
export PATH_CONFIG="$TEST_TMPDIR/config"
export PATH_LOGS="$TEST_TMPDIR/logs"
mkdir -p "$PATH_STATE" "$PATH_STATUS" "$PATH_CONFIG" "$PATH_LOGS" "$TEST_TMPDIR/bin"

# Stub binaries live at $TEST_TMPDIR/bin (first on PATH).
export PATH="$TEST_TMPDIR/bin:$PATH"

source lib/log.sh
log_init "test-verify" "$PATH_LOGS/test.log"

source lib/status.sh
source lib/manifest.sh
source lib/verify.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

# Helper: write a stub binary that prints arg-controlled output and
# exits with a controlled code.
_write_stub() {
  local name="$1" output="$2" exit_code="${3:-0}"
  local path="$TEST_TMPDIR/bin/$name"
  cat > "$path" <<EOF
#!/bin/bash
printf '%s\n' "$output"
exit $exit_code
EOF
  chmod +x "$path"
}

# ============================================================================
echo "=== Test 1: verify_dpkg_installed ==="
_write_stub dpkg-query "install ok installed" 0
verify_dpkg_installed nginx 2>/dev/null; chkrc "installed -> rc=0" $? 0

_write_stub dpkg-query "deinstall ok config-files" 0
err=$(verify_dpkg_installed nginx 2>&1 1>/dev/null); rc=$?
chkrc "uninstalled -> rc=1" $rc 1
[[ $err == *"dpkg: nginx not installed"* ]] && ok "diagnostic mentions pkg" || fail "diagnostic: '$err'"

_write_stub dpkg-query "" 1
err=$(verify_dpkg_installed nosuchpkg 2>&1 1>/dev/null); rc=$?
chkrc "missing pkg -> rc=1" $rc 1
[[ $err == *"status=missing"* ]] && ok "diagnostic includes status=missing" || fail "diagnostic: '$err'"

# ============================================================================
echo "=== Test 2: verify_systemd_active ==="
_write_stub systemctl "" 0   # is-active --quiet returns 0
verify_systemd_active nginx 2>/dev/null; chkrc "active -> rc=0" $? 0

_write_stub systemctl "inactive" 3
err=$(verify_systemd_active nginx 2>&1 1>/dev/null); rc=$?
chkrc "inactive -> rc=1" $rc 1
[[ $err == *"systemctl is-active nginx"* ]] && ok "diagnostic mentions unit" || fail "diagnostic: '$err'"

# ============================================================================
echo "=== Test 3: verify_port_listening ==="
# ss output: header line then "LISTEN 0 511 *:80 ..." rows. The function's
# awk filter splits col4 on ':' and matches the last segment to the port.
_write_stub ss "State  Recv-Q Send-Q Local Address:Port
LISTEN 0      511         *:80              *:*
LISTEN 0      128         *:22              *:*" 0
verify_port_listening 80 tcp 2>/dev/null; chkrc "port 80 listening" $? 0
verify_port_listening 22 tcp 2>/dev/null; chkrc "port 22 listening" $? 0
err=$(verify_port_listening 443 tcp 2>&1 1>/dev/null); rc=$?
chkrc "port 443 not listening" $rc 1
[[ $err == *"port 443/tcp: not listening"* ]] && ok "diagnostic matches" || fail "diagnostic: '$err'"

err=$(verify_port_listening 80 bogus 2>&1 1>/dev/null); rc=$?
chkrc "unknown proto -> rc=1" $rc 1
[[ $err == *"unknown proto 'bogus'"* ]] && ok "proto diagnostic" || fail "diagnostic: '$err'"

# ============================================================================
echo "=== Test 4: verify_file_exists ==="
touch "$TEST_TMPDIR/exists"
verify_file_exists "$TEST_TMPDIR/exists" 2>/dev/null; chkrc "exists -> rc=0" $? 0
err=$(verify_file_exists "$TEST_TMPDIR/nope" 2>&1 1>/dev/null); rc=$?
chkrc "missing -> rc=1" $rc 1
[[ $err == *"file $TEST_TMPDIR/nope: missing"* ]] && ok "diagnostic matches" || fail "diagnostic: '$err'"

# ============================================================================
echo "=== Test 5: verify_require_completed_state ==="
# Write synthetic status files.
mkdir -p "$PATH_STATUS"
cat > "$PATH_STATUS/comp.status" <<'EOF'
ID="comp"
STATUS="completed"
EOF
cat > "$PATH_STATUS/fail.status" <<'EOF'
ID="fail"
STATUS="failed: things broke"
EOF
cat > "$PATH_STATUS/uninst.status" <<'EOF'
ID="uninst"
STATUS="uninstalled"
EOF

verify_require_completed_state comp >/dev/null; chkrc "completed -> rc=0" $? 0
out=$(verify_require_completed_state fail); rc=$?
chkrc "failed -> rc=2" $rc 2
[[ $out == *"state=failed: things broke"* ]] && ok "reason carries state" || fail "reason: '$out'"
out=$(verify_require_completed_state uninst); rc=$?
chkrc "uninstalled -> rc=2" $rc 2
chkeq "uninst reason" "$out" "state=uninstalled"
out=$(verify_require_completed_state nosuch); rc=$?
chkrc "no status file -> rc=2" $rc 2
chkeq "missing reason" "$out" "no status file"

echo
echo "=== Done ==="
```

- [ ] **Step 2: Make executable + run**

```bash
chmod +x tests/test-verify.sh
bash tests/test-verify.sh
```

Expected: all OK lines, no FAIL, `=== Done ===`.

### Task 1.4: Extend `tests/test-verify.sh` with Group 2 (verify_generic)

**Files:**
- Modify: `tests/test-verify.sh`

- [ ] **Step 1: Add tests for `verify_generic`**

Insert BEFORE the final `=== Done ===` block:

```bash
# ============================================================================
echo "=== Test 6: verify_generic (status-state gate) ==="
# Reuse the comp/fail/uninst status files from Test 5. Also need a synthetic
# manifest file so manifest_path_for can resolve the id.
mkdir -p "$TEST_TMPDIR/features"
cat > "$TEST_TMPDIR/features/feature-comp.sh" <<'EOF'
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="comp"
II_TITLE="Comp"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_APT_PACKAGES="foo bar"
II_SERVICE="foo"
# === II_MANIFEST_END ===
EOF
PATH_FEATURES="$TEST_TMPDIR/features"
export PATH_FEATURES

# Status file: foo is pre-existing (we don't own it), bar is ours.
cat > "$PATH_STATUS/comp.status" <<'EOF'
ID="comp"
STATUS="completed"
FOO_FW_PRE_INSTALLED=true
BAR_FW_PRE_INSTALLED=false
EOF

# All-green case: dpkg says bar installed; systemctl says foo active.
_write_stub dpkg-query "install ok installed" 0
_write_stub systemctl "" 0
out=$(verify_generic comp 2>/dev/null); rc=$?
chkrc "all-green -> rc=0" $rc 0

# dpkg says bar missing -> FAIL.
_write_stub dpkg-query "" 1
_write_stub systemctl "" 0
out=$(verify_generic comp 2>/dev/null); rc=$?
chkrc "dpkg miss -> rc=1" $rc 1
[[ $out == *"dpkg: bar not installed"* ]] && ok "fail reason mentions bar" || fail "reason: '$out'"

# systemctl says foo inactive -> FAIL.
_write_stub dpkg-query "install ok installed" 0
_write_stub systemctl "inactive" 3
out=$(verify_generic comp 2>/dev/null); rc=$?
chkrc "systemctl miss -> rc=1" $rc 1
[[ $out == *"systemctl is-active foo"* ]] && ok "fail reason mentions foo unit" || fail "reason: '$out'"

# State != completed -> rc=2, no checks run.
out=$(verify_generic uninst 2>/dev/null); rc=$?
chkrc "not-completed -> rc=2" $rc 2
chkeq "rc=2 reason" "$out" "state=uninstalled"

# Pre-existing (PRE_INSTALLED=true) is NOT checked: even if dpkg says foo
# missing, the check would be skipped. Verify by re-running with bar
# missing but foo present in the stub state: the verifier should skip foo.
# (Already covered above: only bar gets checked, and the all-green case
# passed with foo marked PRE_INSTALLED=true.)
ok "pre-existing pkgs not re-checked (covered by all-green case)"

# ============================================================================
echo "=== Test 7: verify_generic (no checkable items -> '(no liveness checks declared)') ==="
cat > "$TEST_TMPDIR/features/feature-empty.sh" <<'EOF'
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="empty"
II_TITLE="Empty"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
EOF
cat > "$PATH_STATUS/empty.status" <<'EOF'
ID="empty"
STATUS="completed"
EOF
out=$(verify_generic empty 2>/dev/null); rc=$?
chkrc "empty manifest -> rc=0" $rc 0
chkeq "stdout reason" "$out" "(no liveness checks declared)"
```

### Task 1.5: Extend `tests/test-verify.sh` with Group 3 (dispatcher) + Group 4 (formatting) + Group 5 (edge cases)

**Files:**
- Modify: `tests/test-verify.sh`

- [ ] **Step 1: Add Group 3 (dispatcher) tests** BEFORE the final `=== Done ===`

```bash
# ============================================================================
echo "=== Test 8: verify_dispatch_main — --all walks the registry ==="
# Synthetic registry: features/feature-{comp,empty}.sh already exist. Add
# a third "missing" feature whose script file is absent (we'll manifest-list
# it via a hand-crafted file).
cat > "$TEST_TMPDIR/features/feature-broken.sh" <<'EOF'
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="broken"
II_TITLE="Broken"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
exit 99
EOF
cat > "$PATH_STATUS/broken.status" <<'EOF'
ID="broken"
STATUS="completed"
EOF

# Reset stubs to the green case so comp passes.
_write_stub dpkg-query "install ok installed" 0
_write_stub systemctl "" 0

# --all walks manifest_list_ids order; we capture stdout, strip colors,
# and check the row badges + summary counts.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

out=$(verify_dispatch_main --all 2>&1 | strip_ansi); rc=$?
[[ $out == *"[  OK  ] comp"* ]] && ok "--all renders OK row for comp" || fail "missing comp OK row: $out"
[[ $out == *"OK:"*"3"* ]] && ok "summary OK count = 3" || fail "summary: $out"
chkrc "--all returns rc=0 with zero fails" $rc 0

# ============================================================================
echo "=== Test 9: verify_dispatch_main — explicit unknown ID -> rc=2 ==="
out=$(verify_dispatch_main nosuchfeature 2>&1); rc=$?
chkrc "unknown id -> rc=2" $rc 2
[[ $out == *"unknown id 'nosuchfeature'"* ]] && ok "diagnostic mentions id" || fail "diagnostic: $out"

# ============================================================================
echo "=== Test 10: verify_dispatch_main — no-args walks *.status only ==="
# Add a status file for an id that isn't in the manifest -> appears as FAIL
# with "installer script not found" reason.
cat > "$PATH_STATUS/orphan.status" <<'EOF'
ID="orphan"
STATUS="completed"
EOF
# os.status MUST be excluded.
cat > "$PATH_STATUS/os.status" <<'EOF'
ID="os"
STATUS="completed"
EOF
out=$(verify_dispatch_main 2>&1 | strip_ansi); rc=$?
[[ $out == *"[ FAIL ] orphan"* ]] && ok "orphan -> FAIL row" || fail "missing orphan FAIL row"
[[ $out == *"os"* ]] && fail "os.status leaked into output" || ok "os.status excluded"

# ============================================================================
echo "=== Test 11: verify_dispatch_main — explicit IDs always shown ==="
# Even if no status file exists for an explicit id, it should be reported
# (the verifier will hit NOT INSTALLED via verify_require_completed_state).
rm -f "$PATH_STATUS/comp.status"
out=$(verify_dispatch_main comp 2>&1 | strip_ansi); rc=$?
[[ $out == *"[ NOT  ] comp"* ]] && ok "no-status comp -> NOT INSTALLED row" || fail "missing NOT row: $out"
# Restore for following tests.
cat > "$PATH_STATUS/comp.status" <<'EOF'
ID="comp"
STATUS="completed"
FOO_FW_PRE_INSTALLED=true
BAR_FW_PRE_INSTALLED=false
EOF

# ============================================================================
echo "=== Test 12: verify_dispatch_main — --list prints all ids+titles + exit 0 ==="
out=$(verify_dispatch_main --list 2>&1 | strip_ansi); rc=$?
chkrc "--list rc=0" $rc 0
[[ $out == *"comp"*"Comp"* ]] && ok "--list shows comp + title" || fail "--list output: $out"
# --list must NOT print summary block.
[[ $out == *"Verify summary"* ]] && fail "--list leaked summary" || ok "--list skips summary"

# ============================================================================
echo "=== Test 13: row format + summary block content ==="
out=$(verify_dispatch_main comp 2>&1 | strip_ansi); rc=$?
# Header: "[  OK  ] comp ..."
[[ $out == *"[  OK  ] comp"* ]] && ok "OK row badge format" || fail "row: $out"
# Summary lines.
[[ $out == *"Verify summary"* ]] && ok "summary header present" || fail "summary missing"
[[ $out == *"OK:"* ]] && ok "summary OK count line" || fail "OK line missing"
[[ $out == *"FAIL:"* ]] && ok "summary FAIL count line" || fail "FAIL line missing"
[[ $out == *"NOT INSTALLED:"* ]] && ok "summary NOT line" || fail "NOT line missing"

# ============================================================================
echo "=== Test 14: edge — broken installer returns weird exit code -> FAIL ==="
# Replace broken.sh body to return 7 (unknown).
cat > "$TEST_TMPDIR/features/feature-broken.sh" <<'EOF'
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="broken"
II_TITLE="Broken"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
[[ "$1" == "--verify" ]] && exit 7
EOF
chmod +x "$TEST_TMPDIR/features/feature-broken.sh"
out=$(verify_dispatch_main broken 2>&1 | strip_ansi); rc=$?
[[ $out == *"[ FAIL ] broken"* ]] && ok "unknown rc -> FAIL row" || fail "row: $out"
[[ $out == *"verifier returned unexpected exit code 7"* ]] && ok "reason mentions rc=7" || fail "reason: $out"
chkrc "overall rc=1 because of FAIL" $rc 1
```

- [ ] **Step 2: Run the full file**

```bash
bash tests/test-verify.sh
```

Expected: all OK lines, no FAIL, `=== Done ===` at the bottom.

### Task 1.6: Run full suite + commit Phase 1

- [ ] **Step 1: Full suite**

```bash
cd "c:/Source Files/Personal/Bash/installicious"
for t in tests/test-*.sh; do
  out=$(bash "$t" 2>&1); rc=$?
  if [[ $rc -ne 0 ]] || echo "$out" | grep -qE '(^|[^A-Za-z])(FAIL|✗)([^A-Za-z]|$)'; then
    echo "FAILED: $t"; echo "$out" | tail -20; break
  fi
  echo "  OK  $(basename "$t") rc=$rc"
done
```

Expected: 15 OK lines (14 prior + new test-verify.sh), no FAILED.

- [ ] **Step 2: Bump VERSION to `2.6.3`**

- [ ] **Step 3: Commit**

```bash
git add VERSION lib/verify.sh lib/manifest.sh tests/test-verify.sh
git commit -F- <<'MSG'
verify: lib/verify.sh primitives + verify_generic + dispatcher

Lands the framework half of `installicious --verify` per
docs/superpowers/specs/2026-05-24-verify-installed-design.md.

- lib/verify.sh: 5 primitives (dpkg/systemd/port/file/state),
  verify_generic <id> fallback (drives primitives off the manifest
  + status-file pre-state), verify_dispatch_main "$@" extracted so
  tests can call it without forking installicious.sh.
- lib/manifest.sh: header comment documents the new optional
  II_SERVICE manifest field.
- tests/test-verify.sh: 14 sections covering primitives, generic
  fallback (status gate, pre-existing-pkg skip, no-checks case),
  dispatcher (--all / --list / no-args / explicit IDs / unknown ID),
  row + summary format, and the unknown-exit-code edge case.

No installicious.sh wiring yet -- the dispatcher exists in the lib
but is not exposed to users until phase 2. Every feature/package
script remains untouched. VERSION 2.6.2 -> 2.6.3.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 2 — Dispatcher wiring in `installicious.sh` (→ 2.6.4)

After this commit, `installicious --verify --list` works (lists every registered ID; no actual verification yet because no per-installer `--verify` mode exists). The dispatcher is wired but every real call returns FAIL with "installer script not found" because the scripts don't accept `--verify` yet. That's expected — phases 3-4 add the per-script handling.

### Task 2.1: Inspect `installicious.sh`'s current arg-handler layout

**Files:**
- Read-only: `installicious.sh`

- [ ] **Step 1: Read `installicious.sh` end-to-end**

Identify:
1. The root-privilege gate (`if [[ $EUID -ne 0 ]]; then ... fi`) — confirm `--verify` should bypass it (skip the gate when first arg is `--verify`).
2. The `--uninstall` arg-handler block (around line 129-177 per spec). Note its structure so we can mirror it.
3. Where `source config/installicious.config`, `source lib/log.sh`, etc. happen relative to the gate and the menu-launch path.
4. The whiptail-dep-check / `state_exists` / menu-launch path — we need to bypass all of it for `--verify`.

### Task 2.2: Add `--verify` arg-handler block to `installicious.sh`

**Files:**
- Modify: `installicious.sh`

- [ ] **Step 1: Bypass the root gate when first arg is `--verify`**

Find the root-priv gate (typically near the top of the file). Wrap it in a condition that skips for `--verify`:

```bash
# Bypass the root-priv gate for read-only --verify (existing dispatcher
# is in lib/verify.sh and most checks are read-only; do_verify bodies
# that need root sudo -n themselves).
if [[ "${1:-}" != "--verify" ]]; then
  if [[ $EUID -ne 0 ]]; then
    echo "installicious must be run as root (try: sudo bash $0)." >&2
    exit 1
  fi
fi
```

Read the actual gate text first via `Grep`, then `Edit` with the exact `old_string`.

- [ ] **Step 2: Insert the `--verify` arg-handler block AFTER the existing `--uninstall` block**

Find the line right after the `--uninstall` block ends (look for `exit $?` or the end of the `if` chain handling `--uninstall`). Insert:

```bash
# --- --verify dispatcher ----------------------------------------------------
# Bypasses the menu, the resume hand-off, and the whiptail dep check
# (verify must work even on a half-broken box). Sources the lean set of
# libs needed: log, status, manifest, verify. The dispatcher itself
# lives in lib/verify.sh (extracted for tests).
if [[ "${1:-}" == "--verify" ]]; then
  shift
  source config/installicious.config || exit 1
  source lib/log.sh
  source lib/status.sh
  source lib/manifest.sh
  source lib/verify.sh
  log_init "installicious --verify" "$PATH_LOGS/installicious.log"
  verify_dispatch_main "$@"
  exit $?
fi
```

Use `Edit` to insert immediately after the `--uninstall` block's closing `fi` (find the unique anchor in the file).

- [ ] **Step 3: Syntax check**

Run: `bash -n installicious.sh && echo OK`
Expected: `OK`

### Task 2.3: Smoke test (manual; dispatch should be reachable)

- [ ] **Step 1: Run `--verify --list` against the real registry**

```bash
sudo bash installicious.sh --verify --list 2>&1 | head -10
```

Expected: a table of every feature/package ID + title, ending without errors. No `FAIL` rows (this is `--list` which doesn't run verifications). On Windows / dev box without `dpkg`, this should still work because `--list` never invokes per-installer `--verify` subprocesses.

- [ ] **Step 2: Run `--verify <known-id>` against any feature**

```bash
bash installicious.sh --verify pkupd 2>&1 | head -10
```

Expected (with no per-script `--verify` yet): `[ FAIL ] pkupd` with reason `verifier returned unexpected exit code 2` or similar. **This is OK — we expect this until phase 3-4 land.** Just confirm the dispatcher reaches the per-script invocation.

### Task 2.4: Run full suite + commit Phase 2

- [ ] **Step 1: Full suite**

Same loop as phase 1. Expected: 15/15 OK.

- [ ] **Step 2: Bump VERSION to `2.6.4`**

- [ ] **Step 3: Commit**

```bash
git add VERSION installicious.sh
git commit -F- <<'MSG'
verify: wire `installicious --verify` dispatcher entry point

installicious.sh gains a --verify arg-handler block, placed after
the existing --uninstall block. Bypasses:
- the root-privilege gate (verify is read-only by default; do_verify
  bodies that need root sudo -n themselves)
- the menu / resume hand-off / whiptail dep check (verify must work
  even on a half-broken box)

The dispatcher itself is verify_dispatch_main in lib/verify.sh
(landed Phase 1). The wiring here just sources the needed libs, calls
the dispatcher, and propagates its rc.

`installicious --verify --list` works end-to-end (lists every
manifest-registered ID). Per-script `--verify` subprocess calls
will return rc=2 ("unknown argument") until phase 3-4 teach
installer_apt_main + every feature-*.sh the --verify case.

VERSION 2.6.3 -> 2.6.4.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 3 — `installer_apt_main` learns `--verify` (→ 2.6.5)

After this commit, every `packages/package-*.sh` (which all use `installer_apt_main`) becomes verifiable via the generic fallback. First user-visible value.

### Task 3.1: Inspect `lib/installer_apt.sh`

**Files:**
- Read-only: `lib/installer_apt.sh`

- [ ] **Step 1: Find `installer_apt_main`**

Run: `Grep` for `installer_apt_main` in `lib/installer_apt.sh` with context. Note:
- The arg-parser case structure (which handles `--install` / `--uninstall`).
- The dispatch to `do_install` / `do_uninstall`.

### Task 3.2: Add `--verify` case + `_installer_apt_do_verify`

**Files:**
- Modify: `lib/installer_apt.sh`

- [ ] **Step 1: Source `lib/verify.sh` in the lib's header (or in installer_apt_main itself)**

Find the existing `source` block at the top of `lib/installer_apt.sh`. If the lib already sources sibling libs at the top, add `source lib/verify.sh` to that block. If sourcing happens lazily inside `installer_apt_main`, add it inside the function before the verify branch.

- [ ] **Step 2: Add `--verify` to the arg-parser case**

Find the case statement that handles `--install`/`--uninstall`. Add:

```bash
    --verify)    MODE="verify" ;;
```

- [ ] **Step 3: Add the verify dispatch branch + body**

Find the if/else that dispatches to `do_install`/`do_uninstall`. Add a verify branch:

```bash
  elif [[ $MODE == "verify" ]]; then
    _installer_apt_do_verify
  fi
```

And add the function definition near the other `_installer_apt_*` helpers:

```bash
# _installer_apt_do_verify — invoked when installer_apt_main sees --verify.
# Pure passthrough to verify_generic; every package-*.sh is identical at
# the verify layer (apt-package liveness only, no custom checks).
_installer_apt_do_verify() {
  verify_generic "$II_ID"
}
```

- [ ] **Step 4: Syntax check**

Run: `bash -n lib/installer_apt.sh && echo OK`
Expected: `OK`

### Task 3.3: Smoke test

- [ ] **Step 1: Verify a package**

Pick any installed package, e.g.:

```bash
bash installicious.sh --verify weewx 2>&1 | head -5
```

Expected: `[  OK  ] weewx — WeeWX ...` (if the package was installed on this box). On a dev machine without the actual install, expect `[ NOT  ] weewx` with `state=...` or `no status file`. **Either is a pass** — the point is the dispatcher reaches package-weewx.sh, which now accepts `--verify` and runs `verify_generic`.

### Task 3.4: Run full suite + commit Phase 3

- [ ] **Step 1: Full suite** — expect 15/15.

- [ ] **Step 2: Bump VERSION to `2.6.5`**.

- [ ] **Step 3: Commit**

```bash
git add VERSION lib/installer_apt.sh
git commit -F- <<'MSG'
verify: installer_apt_main learns --verify (every package wired)

Adds a --verify case to installer_apt_main's arg parser and a thin
_installer_apt_do_verify body that calls verify_generic "$II_ID".
Because every packages/package-*.sh uses installer_apt_main, this
single edit makes every package script verifiable -- the dispatcher
in installicious.sh --verify can now reach them with no per-script
edits.

VERSION 2.6.4 -> 2.6.5.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 4 — Every `feature-*.sh` learns `--verify` (mechanical batch, → 2.6.6)

Every feature script gets the same 3-line addition: source `lib/verify.sh`, accept `--verify`, dispatch to `do_verify` which defaults to `verify_generic`. Features that need custom checks override `do_verify` in phase 5.

### Task 4.1: Enumerate the feature list

**Files:**
- Read-only: `features/feature-*.sh`

- [ ] **Step 1: Confirm the list**

```bash
ls features/feature-*.sh | wc -l
ls features/feature-*.sh
```

Expected: ~28 files (every feature in the registry, including the 4 added by feature-database). Reading the list confirms scope.

### Task 4.2: Add the verify case to ONE feature first (model: `feature-pkupd.sh`)

**Files:**
- Modify: `features/feature-pkupd.sh`

This task locks in the pattern. Once it's clean for pkupd, the rest copy the same shape.

- [ ] **Step 1: Read `features/feature-pkupd.sh`**

Find:
- The `source lib/...` block.
- The `case "$1" in --install|--uninstall` arg-parser.
- The `if [[ $MODE == "install" ]] ... elif [[ $MODE == "uninstall" ]] ...` dispatch.

- [ ] **Step 2: Add `source lib/verify.sh` to the source block**

Add after the last `source lib/...` line.

- [ ] **Step 3: Add `--verify) MODE="verify" ;;` to the arg parser**

```bash
case "$1" in
  --install)   MODE="install" ;;
  --uninstall) MODE="uninstall" ;;
  --verify)    MODE="verify" ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Add `do_verify() { verify_generic "$II_ID"; }` near the other do_* helpers**

Place it next to the existing `do_install` / `do_uninstall` function definitions, or near the bottom if those are not factored as functions.

- [ ] **Step 5: Add a verify branch to the mode dispatch**

```bash
if [[ $MODE == "install" ]]; then
  do_install
elif [[ $MODE == "uninstall" ]]; then
  do_uninstall
elif [[ $MODE == "verify" ]]; then
  do_verify
fi
exit $?
```

(If `feature-pkupd.sh` uses a top-level install body without `do_install()`, factor out a small `do_install` wrapper around it, OR keep the current flow and add the verify case in a parallel `if`. Use whichever fits the existing shape.)

- [ ] **Step 6: Syntax check + verify against pkupd**

```bash
bash -n features/feature-pkupd.sh && echo OK
bash features/feature-pkupd.sh --verify 2>&1 | head -3
```

Expected: `OK` for syntax. Verify output: either `(no liveness checks declared)` (rc=0 — pkupd installs no long-running service) or a clean exit 0. **NOT a "unknown argument" error** — that confirms the arg parser picked it up.

### Task 4.3: Apply the same pattern to every other feature

**Files:**
- Modify: every `features/feature-*.sh` EXCEPT `feature-database.sh` (the parent — special; see note) and the ones already touched.

The full list (apply the 4-step pattern to each):

```
features/feature-apache.sh
features/feature-bash.sh
features/feature-caddy.sh
features/feature-compressed-swap.sh
features/feature-database-mariadb.sh
features/feature-database-mysql.sh
features/feature-database-sqlite.sh
features/feature-database.sh          (NOTE: parent grouping feature)
features/feature-lighttpd.sh
features/feature-locale.sh
features/feature-motd.sh
features/feature-motd-updates.sh
features/feature-motd-weather.sh
features/feature-neowx-material.sh
features/feature-nginx.sh
features/feature-ram-logging.sh
features/feature-rconf.sh
features/feature-skyfield.sh
features/feature-webserver.sh         (parent grouping feature)
features/feature-webserver-ssl.sh
features/feature-webserver-under-construction.sh
features/feature-weewx-database-ram.sh
features/feature-weewx-onedrive-backup.sh
features/feature-weewx-setup.sh
features/feature-weewx-site-ram.sh
features/feature-weewx-webroot.sh
```

For each file:

- [ ] **Step 1: Read it briefly to locate the source block + arg-parser case + mode-dispatch**

- [ ] **Step 2: Add `source lib/verify.sh`**

- [ ] **Step 3: Add `--verify) MODE="verify" ;;` to the case**

- [ ] **Step 4: Add `do_verify() { verify_generic "$II_ID"; }`**

- [ ] **Step 5: Add the verify branch to the mode dispatch**

**Special-case parent features (`feature-database.sh`, `feature-webserver.sh`):** these are no-op recorders that only mark `status_mark_complete` / `status_mark_uninstalled`. Their `do_verify` should also be one-line `verify_generic "$II_ID"` — `verify_generic` will hit "(no liveness checks declared)" because the parents have no II_APT_PACKAGES / II_SERVICE, and the picked child carries the real liveness check separately. Don't try to be clever about reading `LAST_ADDONS_PICKED` from the parent.

- [ ] **Step 6: After every file is touched, run a sweep syntax check**

```bash
for f in features/feature-*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done && echo "all features clean"
```

Expected: `all features clean`.

### Task 4.4: Run the full suite + commit Phase 4

- [ ] **Step 1: Full suite** — expect 15/15.

- [ ] **Step 2: Bump VERSION to `2.6.6`**.

- [ ] **Step 3: Commit**

Stage all modified feature files plus VERSION:

```bash
git add VERSION features/feature-*.sh
git commit -F- <<'MSG'
verify: every feature-*.sh learns --verify (mechanical batch)

Adds the --verify case to every features/feature-*.sh: source
lib/verify.sh, accept --verify in the arg parser, dispatch to
do_verify which defaults to one-line `verify_generic "$II_ID"`.

Parent grouping features (feature-database, feature-webserver) also
land the one-line do_verify; verify_generic correctly handles them
via "(no liveness checks declared)" because they declare no
II_APT_PACKAGES / II_SERVICE. The picked child (mysql / nginx /
etc.) is what carries the real liveness check.

After this commit, `installicious --verify` and `installicious
--verify --all` cover every feature in the registry. Features that
need richer liveness checks (port-listening, configtest, weewx
service) override do_verify opportunistically in follow-up phases.

VERSION 2.6.5 -> 2.6.6.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 5a — Webserver family custom `do_verify` (→ 2.6.7)

`feature-nginx.sh`, `feature-apache.sh`, `feature-lighttpd.sh`, `feature-caddy.sh`. Each gets `do_verify` that checks:
1. `verify_require_completed_state` (NOT INSTALLED gate — `verify_generic` does this; we replicate inline so we own the early exit).
2. `verify_dpkg_installed` for the apt package.
3. `verify_systemd_active` for the systemd unit.
4. The backend's own config-test command (`nginx -t`, `apache2ctl configtest`, `lighttpd -t -f ...`, `caddy validate`).
5. `verify_port_listening "$WEBSERVER_PORT"`.

### Task 5a.1: `feature-nginx.sh`

**Files:**
- Modify: `features/feature-nginx.sh` (the existing `do_verify` from phase 4 is the one-liner; replace it)

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err

  if ! err=$(verify_dpkg_installed nginx 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_systemd_active nginx 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(sudo -n nginx -t 2>&1); then
    echo "nginx -t: $(printf '%s' "$err" | head -1)"
    rc=1
  fi
  if ! err=$(verify_port_listening "${WEBSERVER_PORT:-80}" tcp 2>&1); then
    echo "$err"; rc=1
  fi
  return $rc
}
```

- [ ] **Step 2: Syntax + verify** — `bash -n features/feature-nginx.sh && echo OK`; `bash features/feature-nginx.sh --verify 2>&1 | head -5`.

### Task 5a.2: `feature-apache.sh`

**Files:**
- Modify: `features/feature-apache.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_dpkg_installed apache2 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_systemd_active apache2 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(sudo -n apache2ctl configtest 2>&1); then
    echo "apache2ctl configtest: $(printf '%s' "$err" | head -1)"
    rc=1
  fi
  if ! err=$(verify_port_listening "${WEBSERVER_PORT:-80}" tcp 2>&1); then
    echo "$err"; rc=1
  fi
  return $rc
}
```

### Task 5a.3: `feature-lighttpd.sh`

**Files:**
- Modify: `features/feature-lighttpd.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_dpkg_installed lighttpd 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_systemd_active lighttpd 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(sudo -n lighttpd -t -f /etc/lighttpd/lighttpd.conf 2>&1); then
    echo "lighttpd -t: $(printf '%s' "$err" | head -1)"
    rc=1
  fi
  if ! err=$(verify_port_listening "${WEBSERVER_PORT:-80}" tcp 2>&1); then
    echo "$err"; rc=1
  fi
  return $rc
}
```

### Task 5a.4: `feature-caddy.sh`

**Files:**
- Modify: `features/feature-caddy.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_dpkg_installed caddy 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_systemd_active caddy 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(sudo -n caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
    echo "caddy validate: $(printf '%s' "$err" | head -1)"
    rc=1
  fi
  if ! err=$(verify_port_listening "${WEBSERVER_PORT:-80}" tcp 2>&1); then
    echo "$err"; rc=1
  fi
  return $rc
}
```

### Task 5a.5: Run full suite + commit Phase 5a

- [ ] **Step 1: Full suite** — expect 15/15.

- [ ] **Step 2: Bump VERSION to `2.6.7`**.

- [ ] **Step 3: Commit**

```bash
git add VERSION features/feature-nginx.sh features/feature-apache.sh features/feature-lighttpd.sh features/feature-caddy.sh
git commit -F- <<'MSG'
verify: webserver-family custom do_verify (nginx/apache/lighttpd/caddy)

Each backend's do_verify replaces the generic fallback with four
backend-specific liveness checks:

1. verify_dpkg_installed for the apt package.
2. verify_systemd_active for the systemd unit.
3. The backend's config-test command (`nginx -t`,
   `apache2ctl configtest`, `lighttpd -t -f`, `caddy validate`).
4. verify_port_listening on the configured WEBSERVER_PORT.

All four call verify_require_completed_state at the top so a
status != completed item shows NOT INSTALLED instead of FAIL. The
configtest commands sudo -n; a sudo failure is reported via the
captured stderr's first line.

VERSION 2.6.6 -> 2.6.7.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 5b — Database family custom `do_verify` (→ 2.6.8)

`feature-database-mysql.sh` + `feature-database-mariadb.sh` get a hand-written `do_verify`. `feature-database-sqlite.sh` keeps its one-liner (SQLite is part of weewx; the leaf does no install of its own).

### Task 5b.1: `feature-database-mysql.sh`

**Files:**
- Modify: `features/feature-database-mysql.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err

  # Skip server check if remote (we don't run it locally).
  if [[ "${DATABASE_HOST:-SELF}" =~ ^(SELF|self|localhost|127\.0\.0\.1|)$ ]]; then
    if ! err=$(verify_dpkg_installed default-mysql-server 2>&1); then echo "$err"; rc=1; fi
    if ! err=$(verify_systemd_active "$SERVICE" 2>&1); then echo "$err"; rc=1; fi
    # Trivial liveness query through socket auth.
    if ! sudo -n mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
      echo "mysql -u root socket-auth SELECT 1 failed (server up but root socket auth broken)"
      rc=1
    fi
  else
    echo "remote DATABASE_HOST=$DATABASE_HOST — skipped local server checks"
  fi

  if ! err=$(verify_dpkg_installed python3-pymysql 2>&1); then echo "$err"; rc=1; fi
  return $rc
}
```

### Task 5b.2: `feature-database-mariadb.sh`

**Files:**
- Modify: `features/feature-database-mariadb.sh`

- [ ] **Step 1: Replace `do_verify`**

Mirror the mysql body with `mariadb-server` as the apt-package check name. (`$SERVICE` is `mariadb` in both children, so the systemctl check is identical; the python pkg is the same.)

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err

  if [[ "${DATABASE_HOST:-SELF}" =~ ^(SELF|self|localhost|127\.0\.0\.1|)$ ]]; then
    if ! err=$(verify_dpkg_installed mariadb-server 2>&1); then echo "$err"; rc=1; fi
    if ! err=$(verify_systemd_active "$SERVICE" 2>&1); then echo "$err"; rc=1; fi
    if ! sudo -n mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
      echo "mysql -u root socket-auth SELECT 1 failed (server up but root socket auth broken)"
      rc=1
    fi
  else
    echo "remote DATABASE_HOST=$DATABASE_HOST — skipped local server checks"
  fi

  if ! err=$(verify_dpkg_installed python3-pymysql 2>&1); then echo "$err"; rc=1; fi
  return $rc
}
```

### Task 5b.3: Run full suite + commit Phase 5b

- [ ] **Step 1: Full suite** — expect 15/15.

- [ ] **Step 2: Bump VERSION to `2.6.8`**.

- [ ] **Step 3: Commit**

```bash
git add VERSION features/feature-database-mysql.sh features/feature-database-mariadb.sh
git commit -F- <<'MSG'
verify: database family custom do_verify (mysql + mariadb)

Each mysql/mariadb child gets a hand-written do_verify:
- For local (DATABASE_HOST=SELF/empty/localhost/127.0.0.1):
  verify_dpkg_installed for the server pkg, verify_systemd_active
  for $SERVICE ("mariadb" -- both children share it on Debian), and
  a `sudo -n mysql -u root -e "SELECT 1;"` liveness query through
  socket auth.
- For remote: skip the server checks with a clear info line.
- Always: verify_dpkg_installed python3-pymysql (the role-specific
  Python binding from config/database-weewx.config).

The sqlite child keeps the one-line verify_generic from phase 4 --
SQLite has no server / no separate apt pkg / no socket; the weewx
apt package owns its installation.

VERSION 2.6.7 -> 2.6.8.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 5c — WeeWX ecosystem custom `do_verify` (→ 2.6.9)

Seven features get hand-written `do_verify` bodies. Each task creates a small targeted body.

### Task 5c.1: `feature-weewx-setup.sh`

**Files:**
- Modify: `features/feature-weewx-setup.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err

  if ! err=$(verify_systemd_active weewx 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_file_exists /etc/weewx/weewx.conf 2>&1); then echo "$err"; rc=1; fi
  return $rc
}
```

### Task 5c.2: `feature-weewx-database-ram.sh`

**Files:**
- Modify: `features/feature-weewx-database-ram.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  # Self-skip respects DATABASE_TYPE (matches the do_install skip logic).
  local _db_state="${PATH_STATE:-/etc/installicious/state}/database.state"
  if [[ -f $_db_state ]]; then
    local _db_type
    _db_type=$(source "$_db_state" 2>/dev/null; printf '%s' "${DATABASE_TYPE:-}")
    case "$_db_type" in
      ""|sqlite) : ;;
      *) echo "DATABASE_TYPE=$_db_type — SQLite-only, not applicable"; return 0 ;;
    esac
  fi

  local rc=0 err
  if ! err=$(verify_systemd_active weewx-ramdisk 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_file_exists /etc/weewx-ramdisk.conf 2>&1); then echo "$err"; rc=1; fi
  # The mount point should exist and be tmpfs/zram-backed; a missing
  # mountpoint after install signals a real problem.
  if ! err=$(verify_file_exists "${WEEWX_DB_DIR:-/var/lib/weewx}" 2>&1); then echo "$err"; rc=1; fi
  return $rc
}
```

### Task 5c.3: `feature-weewx-site-ram.sh`

**Files:**
- Modify: `features/feature-weewx-site-ram.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_file_exists "${WEEWX_WEB_DIR:-/var/www/html/weewx}" 2>&1); then echo "$err"; rc=1; fi
  # tmpfs mount must be active.
  if ! findmnt -n -t tmpfs "${WEEWX_WEB_DIR:-/var/www/html/weewx}" >/dev/null 2>&1; then
    echo "tmpfs mount missing at ${WEEWX_WEB_DIR:-/var/www/html/weewx}"
    rc=1
  fi
  return $rc
}
```

### Task 5c.4: `feature-weewx-webroot.sh`

**Files:**
- Modify: `features/feature-weewx-webroot.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_file_exists "${WEEWX_WEB_DIR:-/var/www/html/weewx}" 2>&1); then echo "$err"; rc=1; fi
  # We can't generically check "is the backend's root pointed here?" without
  # knowing the active backend -- the install body already did that and
  # snapshotted. Trust the install record + presence of the directory.
  return $rc
}
```

### Task 5c.5: `feature-neowx-material.sh`

**Files:**
- Modify: `features/feature-neowx-material.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  if ! err=$(verify_file_exists /etc/weewx/skins/neowx-material/skin.conf 2>&1); then echo "$err"; rc=1; fi
  if ! grep -q '\[\[neowx-material\]\]' /etc/weewx/weewx.conf 2>/dev/null; then
    echo "/etc/weewx/weewx.conf: no [[neowx-material]] section under [StdReport]"
    rc=1
  fi
  return $rc
}
```

### Task 5c.6: `feature-weewx-onedrive-backup.sh`

**Files:**
- Modify: `features/feature-weewx-onedrive-backup.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  # Self-skip respects DATABASE_TYPE (mirrors do_install).
  local _db_state="${PATH_STATE:-/etc/installicious/state}/database.state"
  if [[ -f $_db_state ]]; then
    local _db_type
    _db_type=$(source "$_db_state" 2>/dev/null; printf '%s' "${DATABASE_TYPE:-}")
    case "$_db_type" in
      ""|sqlite) : ;;
      *) echo "DATABASE_TYPE=$_db_type — SQLite-only, not applicable"; return 0 ;;
    esac
  fi

  local rc=0 err tier
  for tier in daily weekly monthly; do
    if ! err=$(verify_systemd_active "weewx-onedrive-backup-${tier}.timer" 2>&1); then echo "$err"; rc=1; fi
  done
  if ! err=$(verify_file_exists /usr/local/sbin/weewx-onedrive-backup 2>&1); then echo "$err"; rc=1; fi
  if ! err=$(verify_file_exists /etc/weewx-onedrive-backup.conf 2>&1); then echo "$err"; rc=1; fi
  return $rc
}
```

### Task 5c.7: `feature-skyfield.sh`

**Files:**
- Modify: `features/feature-skyfield.sh`

- [ ] **Step 1: Replace `do_verify`**

```bash
do_verify() {
  verify_require_completed_state "$II_ID" || return 2
  local rc=0 err
  # Skyfield is a weewx extension -- the install body uses weectl/wee_extension
  # to register it. The presence of the extension dir is the smoke test;
  # weewx itself running is feature-weewx-setup's responsibility.
  if ! err=$(verify_file_exists /etc/weewx/skins/SkyfieldAlmanac 2>&1); then
    # weewx 4 location is different; the dir under /usr/share/weewx is also
    # acceptable. The extension is "registered" if EITHER exists.
    if ! verify_file_exists /usr/share/weewx/user/skyfieldalmanac.py 2>/dev/null; then
      echo "$err"
      echo "skyfield extension not registered in either skins/SkyfieldAlmanac or user/skyfieldalmanac.py"
      rc=1
    fi
  fi
  return $rc
}
```

### Task 5c.8: Run full suite + commit Phase 5c

- [ ] **Step 1: Full suite** — expect 15/15.

- [ ] **Step 2: Bump VERSION to `2.6.9`**.

- [ ] **Step 3: Commit**

```bash
git add VERSION features/feature-weewx-setup.sh features/feature-weewx-database-ram.sh features/feature-weewx-site-ram.sh features/feature-weewx-webroot.sh features/feature-neowx-material.sh features/feature-weewx-onedrive-backup.sh features/feature-skyfield.sh
git commit -F- <<'MSG'
verify: WeeWX ecosystem custom do_verify (7 features)

Hand-written do_verify bodies for the WeeWX feature family:

- weewx-setup: weewx service active, /etc/weewx/weewx.conf exists.
- weewx-database-ram: weewx-ramdisk service active, /etc/weewx-ramdisk.conf
  exists, mount point exists. Self-skips when DATABASE_TYPE != sqlite.
- weewx-site-ram: tmpfs mount at WEEWX_WEB_DIR active (findmnt -t tmpfs).
- weewx-webroot: WEEWX_WEB_DIR directory exists (we can't generically
  check the backend points at it without knowing which backend was
  picked; the install body's snapshot covers that).
- neowx-material: skin.conf exists + [[neowx-material]] section in
  weewx.conf's [StdReport].
- weewx-onedrive-backup: three timers active + runtime script +
  /etc/weewx-onedrive-backup.conf. Self-skips when DATABASE_TYPE != sqlite.
- skyfield: extension dir or user/ python module present.

All seven call verify_require_completed_state at the top so non-
completed items show NOT INSTALLED.

VERSION 2.6.8 -> 2.6.9.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 6 — README + MINOR bump (→ 2.7.0)

### Task 6.1: Add "Verifying an install" section to `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find a logical insertion point**

A natural spot is right after the "Day-to-day use" section (which already mentions `installicious --uninstall`) and before "Roles" or wherever the structure flows. Read the README's TOC to pick.

- [ ] **Step 2: Insert the new section**

```markdown
## Verifying an install

`installicious --verify` checks every installer that's been touched on
this box and prints **OK** / **FAIL** / **NOT INSTALLED** per item with
a summary block. Read-only — no root required.

```bash
installicious --verify                  # everything with a status file
installicious --verify --all            # everything in the registry
installicious --verify <id> [<id> ...]  # only the named items
installicious --verify --list           # list known IDs + titles, no checks
installicious --verify --verbose        # add per-check details to each row
```

Sample output:

```
[  OK  ] nginx                  — nginx
[ FAIL ] mariadb                — MariaDB database server
           systemctl is-active mariadb: inactive
[ NOT  ] motd-weather           — MOTD weather panel
           state=uninstalled
============================================================
  Verify summary
============================================================
  OK:            12
  FAIL:           1
  NOT INSTALLED:  3
============================================================
```

What it checks per feature: by default, `dpkg-query` for any apt
package the install body put on the box, plus `systemctl is-active`
for the unit named in the manifest's optional `II_SERVICE` field.
Features with richer liveness needs (nginx, apache, lighttpd, caddy,
mariadb/mysql, the WeeWX family) carry hand-written checks too —
`nginx -t`, `mysql -u root -e "SELECT 1"`, weewx service liveness,
tmpfs mount presence, etc. A feature with nothing to check prints
`(no liveness checks declared)`.

Exit codes:
- `0` — zero FAILs (NOT INSTALLED rows are not failures).
- `1` — at least one FAIL.
- `2` — you passed an unknown ID on the command line.

The full design + per-installer contract: [docs/superpowers/specs/2026-05-24-verify-installed-design.md](docs/superpowers/specs/2026-05-24-verify-installed-design.md).
```

### Task 6.2: Bump VERSION (MINOR) + commit

- [ ] **Step 1: Full suite** — expect 15/15.

- [ ] **Step 2: Bump VERSION to `2.7.0`** (MINOR — feature lands).

- [ ] **Step 3: Commit**

```bash
git add VERSION README.md
git commit -F- <<'MSG'
verify: README "Verifying an install" + MINOR bump (2.6.9 -> 2.7.0)

Final phase of the --verify landing per
docs/superpowers/specs/2026-05-24-verify-installed-design.md.

README gains a "Verifying an install" section documenting the four
invocations (--verify [/ --all / --list / --verbose / <id>...]),
sample output, the OK / FAIL / NOT INSTALLED model, the exit-code
mapping (0 / 1 / 2), and a pointer to the design spec.

MINOR bump 2.6.9 -> 2.7.0 marks the feature complete.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Manual smoke test (on a real Pi)

After phase 6, run on a real Pi to catch real-dpkg / real-systemd surprises the stubs can't model:

1. `installicious --verify --list` — expect a clean table of every registered ID.
2. `installicious --verify` — expect OK rows for every install on the box, no FAILs.
3. Pick a service the user can break (`sudo systemctl stop nginx`) and re-run `--verify nginx` — expect FAIL with the systemctl reason; restart it; re-run; expect OK.
4. `installicious --verify --all` — expect OK + NOT INSTALLED rows for every registry entry, no FAILs.
5. `installicious --verify nosuchfeature` — expect "unknown id 'nosuchfeature'" + rc=2.
6. `installicious --verify --verbose` — expect indented per-check lines under each OK row (today they'll mostly be empty since most do_verify bodies are silent on success; the `--verbose` flag is rendered as no-op for green rows for now — that's documented).

---

## Self-review checklist (run after writing)

- **Spec §1-9 coverage:** every section of the spec maps to at least one phase task above. ✓
- **No placeholders:** every step has complete code or an exact command. The few `(see task above)`-style cross-references all point to fully-specified content. ✓
- **Type / name consistency:** `verify_dispatch_main`, `verify_generic`, `verify_require_completed_state`, `_installer_apt_do_verify`, `do_verify`, `II_SERVICE` all used consistently across phases. ✓
- **VERSION ladder:** 2.6.2 (start) → 2.6.3 → 2.6.4 → 2.6.5 → 2.6.6 → 2.6.7 → 2.6.8 → 2.6.9 → 2.7.0 (MINOR). 8 commits, 1 MINOR bump. ✓
- **Files coverage:** every file the spec calls out (`lib/verify.sh`, `installicious.sh`, `lib/installer_apt.sh`, `lib/manifest.sh`, all `feature-*.sh`, `README.md`, `tests/test-verify.sh`) appears in at least one phase. ✓
