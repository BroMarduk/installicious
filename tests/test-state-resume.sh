#!/bin/bash
# Tests for lib/state.sh and the scheduler's resume behavior across simulated
# reboots. Stubs systemctl/sudo/shutdown so this runs on the dev machine.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

export LIB_LOG_USE_SUDO=0

source lib/log.sh
source lib/status.sh
source lib/manifest.sh
source lib/state.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
TMPSTATE=$(mktemp -d)
TMPLOG=$(mktemp)
trap "rm -rf $TMPDIR $TMPSTATE $TMPLOG" EXIT

export PATH_FEATURES="$TMPDIR"
export PATH_PACKAGES="$TMPDIR"
export PATH_STATE="$TMPSTATE"

# ===========================================================================
echo "=== Test 1: state_save / state_load round-trip ==="
state_save "git pip pkupd" 1 "test reason" "test-trigger"
unset II_QUEUE_IDS II_QUEUE_CURSOR II_QUEUE_REASON II_QUEUE_TRIGGER II_QUEUE_STARTED_AT
state_load
chkeq "IDS"     "$II_QUEUE_IDS"     "git pip pkupd"
chkeq "CURSOR"  "$II_QUEUE_CURSOR"  "1"
chkeq "REASON"  "$II_QUEUE_REASON"  "test reason"
chkeq "TRIGGER" "$II_QUEUE_TRIGGER" "test-trigger"
[[ -n $II_QUEUE_STARTED_AT ]] && ok "STARTED_AT recorded"

# ===========================================================================
echo
echo "=== Test 2: state_save_cursor preserves other fields ==="
state_save_cursor 2
unset II_QUEUE_IDS II_QUEUE_CURSOR II_QUEUE_REASON II_QUEUE_TRIGGER
state_load
chkeq "cursor advanced" "$II_QUEUE_CURSOR" "2"
chkeq "ids preserved" "$II_QUEUE_IDS" "git pip pkupd"
chkeq "reason preserved" "$II_QUEUE_REASON" "test reason"

# ===========================================================================
echo
echo "=== Test 3: state_exists / state_clear ==="
state_exists; chkrc "exists when present" $? 0
state_clear
state_exists; chkrc "absent after clear" $? 1

# ===========================================================================
echo
echo "=== Test 4: scheduler persists cursor and resume picks up ==="
# Build synthetic installers.
mk_installer() {
  local id="$1" deps="$2" rc="${3:-0}"
  cat > "$TMPDIR/feature-$id.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="$id"
II_TITLE="$id"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS="$deps"
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
echo "$id" >> "$TMPLOG"
exit $rc
EOF
  chmod +x "$TMPDIR/feature-$id.sh"
}
> "$TMPLOG"
mk_installer s1 ""
mk_installer s2 ""    # will simulate reboot via exit 255 the first time
mk_installer s3 ""
mk_installer s4 ""

source lib/scheduler.sh
log_init "test" "/dev/null"

# First pass: s2 returns 255 → halt at cursor 1 (s2's index).
mk_installer s2 "" 255
scheduler_run_queue s1 s2 s3 s4 >/dev/null 2>&1; rc=$?
chkrc "first pass returns 255" $rc 255

# Verify state has cursor=1 (s2 is at index 1 and didn't advance past).
unset II_QUEUE_IDS II_QUEUE_CURSOR
state_load
chkeq "cursor at 1 (s2 needs re-run)" "$II_QUEUE_CURSOR" "1"
chkeq "queue persisted"               "$II_QUEUE_IDS"    "s1 s2 s3 s4"

ran_first=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "first pass ran s1, s2 only" "$ran_first" "s1 s2 "

# Second pass: simulate post-reboot. Make s2 succeed this time.
mk_installer s2 "" 0
scheduler_resume >/dev/null 2>&1; rc=$?
chkrc "resume exit 0" $rc 0

ran_total=$(cat "$TMPLOG" | tr "\n" " ")
chkeq "resume ran s2,s3,s4 (no s1 re-run)" "$ran_total" "s1 s2 s2 s3 s4 "

# State should be cleared after success.
state_exists; chkrc "state cleared on success" $? 1

# ===========================================================================
echo
echo "=== Test 5: scheduler_resume with no state returns 1 ==="
state_clear 2>/dev/null
scheduler_resume >/dev/null 2>&1; rc=$?
chkrc "no state -> rc=1" $rc 1

# ===========================================================================
echo
echo "=== Test 6: state_save with empty fields ==="
state_save "single" 0 "" ""
state_load
chkeq "empty reason" "$II_QUEUE_REASON" ""
chkeq "empty trigger" "$II_QUEUE_TRIGGER" ""
chkeq "ids stored" "$II_QUEUE_IDS" "single"
state_clear

echo
echo "=== Done ==="
