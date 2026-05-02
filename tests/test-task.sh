#!/bin/bash
# Tests for lib/task.sh — extraction, parsing, registry helpers.
# Mirrors test-manifest.sh's structure; uses synthetic tasks in a tempdir
# plus sanity-checks against the real tasks/ directory.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/task.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/task-foo.sh" <<'EOF'
#!/bin/bash
# === II_TASK_BEGIN ===
TASK_ID="foo"
TASK_TITLE="Foo Task"
TASK_DESCRIPTION="A pretend task"
TASK_INSTALLERS_REQUIRED="alpha beta"
TASK_INSTALLERS_OPTIONAL="gamma"
TASK_CONFIG="config/task-foo.config"
TASK_EDITABLE_CONFIG="FOO_HOSTNAME"
# === II_TASK_END ===
echo "BODY EXECUTED — BAD" >&2
exit 99
EOF

cat > "$TMPDIR/task-bar.sh" <<'EOF'
#!/bin/bash
# === II_TASK_BEGIN ===
TASK_ID="bar"
TASK_TITLE="Bar Task"
TASK_DESCRIPTION="Another pretend task"
TASK_INSTALLERS_REQUIRED=""
TASK_INSTALLERS_OPTIONAL=""
TASK_CONFIG=""
TASK_EDITABLE_CONFIG=""
# === II_TASK_END ===
echo "should not run"
EOF

cat > "$TMPDIR/task-no-manifest.sh" <<'EOF'
#!/bin/bash
echo "no-manifest task"
EOF

# A non-task file should be ignored.
echo "not a task" > "$TMPDIR/README.txt"

# ===========================================================================
echo "=== Test 1: task_extract returns block content ==="
extracted=$(task_extract "$TMPDIR/task-foo.sh")
echo "$extracted" | grep -q '^TASK_ID="foo"$'                              && ok "ID line present"
echo "$extracted" | grep -q '^TASK_TITLE="Foo Task"$'                      && ok "TITLE line present"
echo "$extracted" | grep -q '^TASK_INSTALLERS_REQUIRED="alpha beta"$'      && ok "REQUIRED line present"
echo "$extracted" | grep -q "BODY EXECUTED" && fail "leaked body content"  || ok "no body content leaked"

# ===========================================================================
echo
echo "=== Test 2: task_get_field for various types ==="
chkeq "ID"          "$(task_get_field "$TMPDIR/task-foo.sh" TASK_ID)"                  "foo"
chkeq "TITLE space" "$(task_get_field "$TMPDIR/task-foo.sh" TASK_TITLE)"               "Foo Task"
chkeq "REQUIRED"    "$(task_get_field "$TMPDIR/task-foo.sh" TASK_INSTALLERS_REQUIRED)" "alpha beta"
chkeq "OPTIONAL"    "$(task_get_field "$TMPDIR/task-foo.sh" TASK_INSTALLERS_OPTIONAL)" "gamma"
chkeq "missing"     "$(task_get_field "$TMPDIR/task-foo.sh" NONEXISTENT)"              ""
chkeq "no manifest" "$(task_get_field "$TMPDIR/task-no-manifest.sh" TASK_ID)"          ""

# ===========================================================================
echo
echo "=== Test 3: parsing does NOT execute task body ==="
out=$(task_get_field "$TMPDIR/task-foo.sh" TASK_ID 2>&1)
[[ $out == "foo" && $out != *"BODY EXECUTED"* ]] && ok "body not executed during get_field"

# ===========================================================================
echo
echo "=== Test 4: task_list_files / list_ids ==="
files=$(task_list_files "$TMPDIR" | wc -l)
chkeq "list_files count (3 task-*.sh files)" "$files" "3"
ids=$(task_list_ids "$TMPDIR" | sort | tr "\n" ",")
chkeq "list_ids skips no-manifest" "$ids" "bar,foo,"

# ===========================================================================
echo
echo "=== Test 5: task_path_for ==="
chkeq "path_for foo" "$(task_path_for foo "$TMPDIR")" "$TMPDIR/task-foo.sh"
task_path_for nonexistent "$TMPDIR" >/dev/null; rc=$?
chkrc "path_for nonexistent rc=1" $rc 1

# ===========================================================================
echo
echo "=== Test 6: real tasks/ directory has the expected starter set ==="
real_ids=$(task_list_ids tasks | sort | tr "\n" ",")
chkeq "real tasks discovered" "$real_ids" "custom,headless,"

# Each registered ID must point to its own task-<id>.sh file.
mismatched=""
for id in $(task_list_ids tasks); do
  path=$(task_path_for "$id" tasks)
  base=$(basename "$path" .sh)
  expected="task-$id"
  [[ $base == "$expected" ]] || mismatched+=" $id($base)"
done
chkeq "ID matches filename" "$mismatched" ""

# Custom task is the special fallthrough — verify its required/optional lists
# are empty (the menu logic relies on this).
chkeq "custom has no required" "$(task_get_field "$(task_path_for custom tasks)" TASK_INSTALLERS_REQUIRED)" ""
chkeq "custom has no optional" "$(task_get_field "$(task_path_for custom tasks)" TASK_INSTALLERS_OPTIONAL)" ""

# Headless task must reference real installers.
required=$(task_get_field "$(task_path_for headless tasks)" TASK_INSTALLERS_REQUIRED)
chkeq "headless required ids set" "$required" "pkupd rconf bash"

source lib/manifest.sh
for id in $required; do
  path=$(manifest_path_for "$id" installers)
  if [[ -n $path ]]; then
    ok "headless required '$id' resolves to installer manifest"
  else
    fail "headless required '$id' has no installer manifest"
  fi
done

echo
echo "=== Done ==="
