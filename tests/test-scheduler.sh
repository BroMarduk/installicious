#!/bin/bash
# Tests for lib/scheduler.sh — dependency resolution, topo sort, run queue.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

export LIB_LOG_USE_SUDO=0   # tee --append works without sudo for testing

source lib/log.sh
source lib/status.sh
source lib/manifest.sh
source lib/scheduler.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

# Build a synthetic manifest registry for testing. Each "installer" is just a
# shell script that records its invocation and returns a configurable exit code.
TMPDIR=$(mktemp -d)
TMPLOG=$(mktemp)
trap "rm -rf $TMPDIR $TMPLOG" EXIT

# Override the default installer dir so manifest helpers see our synthetic ones.
export PATH_INSTALLERS="$TMPDIR"

mk_installer() {
  local id="$1" deps="$2" rc="${3:-0}"
  cat > "$TMPDIR/install-$id.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="$id"
II_TITLE="$id installer"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS="$deps"
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
echo "$id" >> "$TMPLOG"
exit $rc
EOF
  chmod +x "$TMPDIR/install-$id.sh"
}

reset_log() { > "$TMPLOG"; }

# ===========================================================================
echo "=== Test 1: resolve_deps with no deps ==="
mk_installer alone ""
mk_installer single "alone"
got=$(scheduler_resolve_deps alone | sort | tr "\n" ",")
chkeq "alone -> alone" "$got" "alone,"

# ===========================================================================
echo
echo "=== Test 2: resolve_deps adds direct dep ==="
got=$(scheduler_resolve_deps single | sort | tr "\n" ",")
chkeq "single -> single,alone" "$got" "alone,single,"

# ===========================================================================
echo
echo "=== Test 3: resolve_deps adds transitive deps ==="
mk_installer a ""
mk_installer b "a"
mk_installer c "b"
mk_installer d "c"
got=$(scheduler_resolve_deps d | sort | tr "\n" ",")
chkeq "d -> a,b,c,d" "$got" "a,b,c,d,"

# ===========================================================================
echo
echo "=== Test 4: resolve_deps deduplicates ==="
mk_installer x ""
mk_installer y "x"
mk_installer z "x y"
got=$(scheduler_resolve_deps z | sort | tr "\n" ",")
chkeq "z -> x,y,z (no dup x)" "$got" "x,y,z,"

# ===========================================================================
echo
echo "=== Test 5: topo_sort orders deps before dependents ==="
sorted=$(scheduler_topo_sort a b c d | tr "\n" " ")
# a must come before b,c,d; b before c,d; c before d.
[[ $sorted == "a b c d " ]] && ok "linear chain a→b→c→d ordered correctly" || fail "got '$sorted'"

# ===========================================================================
echo
echo "=== Test 6: topo_sort with diamond (a→b, a→c, b→d, c→d) ==="
mk_installer da ""
mk_installer db "da"
mk_installer dc "da"
mk_installer dd "db dc"
sorted=$(scheduler_topo_sort da db dc dd | tr "\n" " ")
# da must come first, dd must come last.
[[ $sorted == da* ]] && ok "diamond: starts with da"
[[ $sorted == *"dd " ]] && ok "diamond: ends with dd"

# ===========================================================================
echo
echo "=== Test 7: topo_sort detects cycle ==="
mk_installer cyc1 "cyc2"
mk_installer cyc2 "cyc1"
out=$(scheduler_topo_sort cyc1 cyc2 2>&1); rc=$?
chkrc "cycle detection" $rc 2
echo "$out" | grep -q "cycle detected" && ok "cycle error message" || fail "no cycle error"

# ===========================================================================
echo
echo "=== Test 8: run_queue runs installers in order ==="
log_init "scheduler-test" "/dev/null"   # no log file noise
reset_log
mk_installer rq1 ""
mk_installer rq2 "rq1"
mk_installer rq3 "rq2"
sorted=$(scheduler_topo_sort rq1 rq2 rq3 | tr "\n" " ")
scheduler_run_queue $sorted >/dev/null 2>&1; rc=$?
chkrc "run_queue exit 0" $rc 0
order=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "execution order" "$order" "rq1 rq2 rq3 "

# ===========================================================================
echo
echo "=== Test 9: run_queue halts on exit 255 (reboot signal) ==="
reset_log
mk_installer rb1 ""
mk_installer rb2 "" 255      # halts the queue
mk_installer rb3 ""
scheduler_run_queue rb1 rb2 rb3 >/dev/null 2>&1; rc=$?
chkrc "run_queue returns 255 on reboot" $rc 255
order=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "rb3 was NOT executed after reboot signal" "$order" "rb1 rb2 "

# ===========================================================================
echo
echo "=== Test 10: run_queue continues past non-reboot failures ==="
reset_log
mk_installer fa ""
mk_installer fb "" 7         # fails, but not 255
mk_installer fc ""
scheduler_run_queue fa fb fc >/dev/null 2>&1; rc=$?
order=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "all three ran despite fb failure" "$order" "fa fb fc "
[[ $rc -eq 7 ]] && ok "overall rc reflects last failure" || fail "rc=$rc, want 7"

# ===========================================================================
echo
echo "=== Test 11: run_queue skips unregistered IDs with a warning ==="
reset_log
mk_installer reg ""
out=$(scheduler_run_queue reg unknown-id 2>&1); rc=$?
chkrc "skip + run remaining" $rc 0
order=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "only registered ran" "$order" "reg "
echo "$out" | grep -q "no installer registered" && ok "warning logged for unknown ID" || fail "no warning"

# ===========================================================================
echo
echo "=== Test 12: scheduler_run_resolved — convenience wrapper ==="
reset_log
mk_installer rr1 ""
mk_installer rr2 "rr1"
mk_installer rr3 "rr2"
scheduler_run_resolved rr3 >/dev/null 2>&1; rc=$?
chkrc "run_resolved exit 0" $rc 0
order=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "transitive resolution + ordering" "$order" "rr1 rr2 rr3 "

# ===========================================================================
echo
echo "=== Test 13: resolve_deps fails hard when an ID has no installer ==="
err=$(scheduler_resolve_deps does-not-exist 2>&1 >/dev/null); rc=$?
chkrc "missing top-level ID rc=1" $rc 1
echo "$err" | grep -qi "missing installer" && ok "error mentions 'missing installer'" \
  || fail "error message did not mention missing installer (got: $err)"

# ===========================================================================
echo
echo "=== Test 14: resolve_deps fails hard when a transitive dep is missing ==="
mk_installer parent "ghost-dep"
# 'ghost-dep' has no installer file.
err=$(scheduler_resolve_deps parent 2>&1 >/dev/null); rc=$?
chkrc "missing transitive dep rc=1" $rc 1
echo "$err" | grep -q "ghost-dep" && ok "error names the missing dep" \
  || fail "error did not name 'ghost-dep' (got: $err)"

# ===========================================================================
echo
echo "=== Test 15: run_resolved propagates rc=3 when deps don't resolve ==="
reset_log
scheduler_run_resolved parent >/dev/null 2>&1; rc=$?
chkrc "rc=3 from missing dep" $rc 3
chkeq "no installers ran when deps unresolvable" "$(cat "$TMPLOG")" ""
[[ -n "$SCHEDULER_LAST_ERROR" ]] && ok "SCHEDULER_LAST_ERROR populated" \
  || fail "SCHEDULER_LAST_ERROR was empty after rc=3"
echo "$SCHEDULER_LAST_ERROR" | grep -q "ghost-dep" && ok "SCHEDULER_LAST_ERROR names missing dep" \
  || fail "SCHEDULER_LAST_ERROR did not name 'ghost-dep'"

# ===========================================================================
echo
echo "=== Test 16: skyfield → weewx dep resolves cleanly with both present ==="
# Now that install-weewx.sh is real, picking skyfield should resolve to
# {skyfield, weewx} without needing scheduler_run_queue at all (we just
# verify the dep graph is well-formed).
mk_installer weewx-fake ""
mk_installer skyfield-fake "weewx-fake"
got=$(scheduler_resolve_deps skyfield-fake | sort | tr "\n" ",")
chkeq "skyfield-fake -> skyfield-fake,weewx-fake" "$got" "skyfield-fake,weewx-fake,"

echo
echo "=== Done ==="
