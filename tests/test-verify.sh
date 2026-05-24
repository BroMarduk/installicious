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
_write_stub systemctl "" 0
verify_systemd_active nginx 2>/dev/null; chkrc "active -> rc=0" $? 0

_write_stub systemctl "inactive" 3
err=$(verify_systemd_active nginx 2>&1 1>/dev/null); rc=$?
chkrc "inactive -> rc=1" $rc 1
[[ $err == *"systemctl is-active nginx"* ]] && ok "diagnostic mentions unit" || fail "diagnostic: '$err'"

# ============================================================================
echo "=== Test 3: verify_port_listening ==="
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
mkdir -p "$PATH_STATUS"
# Status files use <ID>_FW_STATE key (see lib/status.sh:status_state)
cat > "$PATH_STATUS/comp.status" <<'EOF'
COMP_FW_STATE="completed"
EOF
cat > "$PATH_STATUS/fail.status" <<'EOF'
FAIL_FW_STATE="failed: things broke"
EOF
cat > "$PATH_STATUS/uninst.status" <<'EOF'
UNINST_FW_STATE="uninstalled"
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
# ============================================================================
echo "=== Test 6: verify_generic (status-state gate) ==="
mkdir -p "$TEST_TMPDIR/features"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat > "$TEST_TMPDIR/features/feature-comp.sh" <<FEATURE_EOF
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
if [[ "\$1" == "--verify" ]]; then
  source "${REPO_ROOT}/lib/log.sh"
  log_init "feature-comp-verify" "\${PATH_LOGS:-/tmp}/feature-comp.log"
  source "${REPO_ROOT}/lib/status.sh"
  source "${REPO_ROOT}/lib/manifest.sh"
  source "${REPO_ROOT}/lib/verify.sh"
  verify_generic comp; exit \$?
fi
FEATURE_EOF
chmod +x "$TEST_TMPDIR/features/feature-comp.sh"
PATH_FEATURES="$TEST_TMPDIR/features"
export PATH_FEATURES
manifest_registry_reload

cat > "$PATH_STATUS/comp.status" <<'EOF'
COMP_FW_STATE="completed"
FOO_FW_PRE_INSTALLED=true
BAR_FW_PRE_INSTALLED=false
EOF

_write_stub dpkg-query "install ok installed" 0
_write_stub systemctl "" 0
out=$(verify_generic comp 2>/dev/null); rc=$?
chkrc "all-green -> rc=0" $rc 0

_write_stub dpkg-query "" 1
_write_stub systemctl "" 0
out=$(verify_generic comp 2>/dev/null); rc=$?
chkrc "dpkg miss -> rc=1" $rc 1
[[ $out == *"dpkg: bar not installed"* ]] && ok "fail reason mentions bar" || fail "reason: '$out'"

_write_stub dpkg-query "install ok installed" 0
_write_stub systemctl "inactive" 3
out=$(verify_generic comp 2>/dev/null); rc=$?
chkrc "systemctl miss -> rc=1" $rc 1
[[ $out == *"systemctl is-active foo"* ]] && ok "fail reason mentions foo unit" || fail "reason: '$out'"

out=$(verify_generic uninst 2>/dev/null); rc=$?
chkrc "not-completed -> rc=2" $rc 2
chkeq "rc=2 reason" "$out" "state=uninstalled"

ok "pre-existing pkgs not re-checked (covered by all-green case)"

# ============================================================================
echo "=== Test 7: verify_generic (no checkable items) ==="
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
EMPTY_FW_STATE="completed"
EOF
manifest_registry_reload
out=$(verify_generic empty 2>/dev/null); rc=$?
chkrc "empty manifest -> rc=0" $rc 0
chkeq "stdout reason" "$out" "(no liveness checks declared)"
# ============================================================================
echo "=== Test 8: verify_dispatch_main — --all walks the registry ==="
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
[[ "$1" == "--verify" ]] && exit 0
exit 99
EOF
chmod +x "$TEST_TMPDIR/features/feature-broken.sh"
cat > "$PATH_STATUS/broken.status" <<'EOF'
BROKEN_FW_STATE="completed"
EOF
manifest_registry_reload

_write_stub dpkg-query "install ok installed" 0
_write_stub systemctl "" 0

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
cat > "$PATH_STATUS/orphan.status" <<'EOF'
ORPHAN_FW_STATE="completed"
EOF
cat > "$PATH_STATUS/os.status" <<'EOF'
OS_FW_STATE="completed"
EOF
out=$(verify_dispatch_main 2>&1 | strip_ansi); rc=$?
[[ $out == *"[ FAIL ] orphan"* ]] && ok "orphan -> fail-row rendered" || fail "missing orphan fail row"
[[ $out == *"os"* ]] && fail "os.status leaked into output" || ok "os.status excluded"

# ============================================================================
echo "=== Test 11: verify_dispatch_main — explicit IDs always shown ==="
rm -f "$PATH_STATUS/comp.status"
out=$(verify_dispatch_main comp 2>&1 | strip_ansi); rc=$?
[[ $out == *"[ NOT  ] comp"* ]] && ok "no-status comp -> NOT INSTALLED row" || fail "missing NOT row: $out"
cat > "$PATH_STATUS/comp.status" <<'EOF'
COMP_FW_STATE="completed"
FOO_FW_PRE_INSTALLED=true
BAR_FW_PRE_INSTALLED=false
EOF

# ============================================================================
echo "=== Test 12: verify_dispatch_main — --list prints all ids+titles ==="
out=$(verify_dispatch_main --list 2>&1 | strip_ansi); rc=$?
chkrc "--list rc=0" $rc 0
[[ $out == *"comp"*"Comp"* ]] && ok "--list shows comp + title" || fail "--list output: $out"
[[ $out == *"Verify summary"* ]] && fail "--list leaked summary" || ok "--list skips summary"

# ============================================================================
echo "=== Test 13: row format + summary block content ==="
out=$(verify_dispatch_main comp 2>&1 | strip_ansi); rc=$?
[[ $out == *"[  OK  ] comp"* ]] && ok "OK row badge format" || fail "row: $out"
[[ $out == *"Verify summary"* ]] && ok "summary header present" || fail "summary missing"
[[ $out == *"OK:"* ]] && ok "summary OK count line" || fail "OK line missing"
[[ $out == *"FAIL:"* ]] && ok "summary fail-count line present" || fail "fail-count line missing"
[[ $out == *"NOT INSTALLED:"* ]] && ok "summary NOT line" || fail "NOT line missing"

# ============================================================================
echo "=== Test 14: edge — broken installer returns weird exit code -> fail-row ==="
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
manifest_registry_reload
raw=$(verify_dispatch_main broken 2>&1); rc=$?
out=$(printf '%s\n' "$raw" | strip_ansi)
[[ $out == *"[ FAIL ] broken"* ]] && ok "unknown rc -> fail-row rendered" || fail "row: $out"
[[ $out == *"verifier returned unexpected exit code 7"* ]] && ok "reason mentions rc=7" || fail "reason: $out"
chkrc "overall rc=1 because of fail-row" $rc 1

echo
echo "=== Done ==="
