#!/bin/bash
# Tests for lib/status.sh — focused on installer IDs that contain dashes.
# Bash variable names cannot contain `-`, so any helper that constructs a
# variable name from the ID (status_state, status_should_skip, status_mark_*)
# must translate dashes to underscores. Regression coverage for the bug
# `MOTD-WEATHER_FW_STATE: invalid variable name`.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/status.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export PATH_STATUS="$TMPDIR/status"
mkdir -p "$PATH_STATUS"

# ===========================================================================
echo "=== Test 1: _status_var_prefix translates dashes to underscores ==="
chkeq "no-dash id"          "$(_status_var_prefix git)"           "GIT_FW_"
chkeq "single-dash id"      "$(_status_var_prefix motd-weather)"  "MOTD_WEATHER_FW_"
chkeq "multi-dash id"       "$(_status_var_prefix foo-bar-baz)"   "FOO_BAR_BAZ_FW_"
chkeq "uppercase already"   "$(_status_var_prefix Already-Caps)"  "ALREADY_CAPS_FW_"

# ===========================================================================
echo
echo "=== Test 2: status_mark_started works on a dash-id (no 'invalid variable name') ==="
status_mark_started "motd-weather" 2>"$TMPDIR/err.log"
rc=$?
chkrc "rc=0" $rc 0
[[ -s $TMPDIR/err.log ]] && fail "stderr not empty: $(cat "$TMPDIR/err.log")" || ok "no stderr noise"
[[ -f "$PATH_STATUS/motd-weather.status" ]] && ok "status file created"
grep -q '^MOTD_WEATHER_FW_STATE="running"' "$PATH_STATUS/motd-weather.status" \
  && ok "MOTD_WEATHER_FW_STATE=running written" \
  || fail "expected line not found in status file: $(cat "$PATH_STATUS/motd-weather.status")"

# ===========================================================================
echo
echo "=== Test 3: status_state reads dash-id state without indirect-expansion error ==="
got=$(status_state "motd-weather" 2>"$TMPDIR/err.log")
rc=$?
chkrc "rc=0" $rc 0
[[ -s $TMPDIR/err.log ]] && fail "stderr not empty: $(cat "$TMPDIR/err.log")" || ok "no stderr noise"
chkeq "state echoed" "$got" "running"

# ===========================================================================
echo
echo "=== Test 4: status_mark_complete + status_should_skip dash-id round-trip ==="
status_mark_complete "motd-weather" "1" "" 2>"$TMPDIR/err.log"
[[ -s $TMPDIR/err.log ]] && fail "mark_complete stderr: $(cat "$TMPDIR/err.log")" || ok "mark_complete clean"
status_should_skip "motd-weather" "1" 2>"$TMPDIR/err.log"
rc=$?
chkrc "should_skip on completed v1" $rc 0
[[ -s $TMPDIR/err.log ]] && fail "should_skip stderr: $(cat "$TMPDIR/err.log")" || ok "should_skip clean"

status_should_skip "motd-weather" "2" 2>/dev/null
rc=$?
chkrc "should NOT skip when version differs" $rc 1

# ===========================================================================
echo
echo "=== Test 5: status_mark_failed + status_mark_uninstalled dash-id ==="
rm -f "$PATH_STATUS/motd-weather.status"
status_mark_started "motd-weather"
status_mark_failed "motd-weather" "boom" 2>"$TMPDIR/err.log"
[[ -s $TMPDIR/err.log ]] && fail "mark_failed stderr: $(cat "$TMPDIR/err.log")" || ok "mark_failed clean"
chkeq "state=failed" "$(status_state motd-weather)" "failed"
grep -q '^MOTD_WEATHER_FW_LAST_ERROR="boom"' "$PATH_STATUS/motd-weather.status" \
  && ok "LAST_ERROR recorded" \
  || fail "LAST_ERROR not in file"

status_mark_uninstalled "motd-weather" 2>"$TMPDIR/err.log"
[[ -s $TMPDIR/err.log ]] && fail "mark_uninstalled stderr: $(cat "$TMPDIR/err.log")" || ok "mark_uninstalled clean"
chkeq "state=uninstalled" "$(status_state motd-weather)" "uninstalled"

# ===========================================================================
echo
echo "=== Test 6: regression — direct sourcing of dash-id status file works ==="
# A status file written by the (fixed) helpers must be valid bash to source.
# The old bug would have written keys like MOTD-WEATHER_FW_STATE which is
# invalid syntax and breaks any state_load / status_get follow-up.
set +e
( source "$PATH_STATUS/motd-weather.status" 2>"$TMPDIR/err.log" )
src_rc=$?
set -e
chkrc "source rc=0" $src_rc 0
[[ -s $TMPDIR/err.log ]] && fail "source stderr: $(cat "$TMPDIR/err.log")" || ok "no syntax errors when sourced"

echo
echo "=== Done ==="
