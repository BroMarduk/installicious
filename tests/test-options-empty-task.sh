#!/bin/bash
# Tests the dispatcher branches in scripts/options.sh that handle a task with
# no required AND no optional installers. The decisions live inline in the
# state machine; this file mirrors the logic so we get fast unit coverage of
# the empty-task corner without driving whiptail.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/task.sh
source lib/manifest.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Synthetic empty task — mirrors the data shape of a manifest with no
# required and no optional installers.
cat > "$TMPDIR/task-empty.sh" <<'EOF'
#!/bin/bash
# === II_TASK_BEGIN ===
TASK_ID="empty"
TASK_TITLE="Empty Task"
TASK_DESCRIPTION="No installers; degenerate but supported"
TASK_INSTALLERS_REQUIRED=""
TASK_INSTALLERS_OPTIONAL=""
TASK_CONFIG=""
TASK_EDITABLE_CONFIG=""
# === II_TASK_END ===
EOF

# ===========================================================================
echo "=== Test 1: empty-task manifest parses to empty fields ==="
task_path="$TMPDIR/task-empty.sh"
required=$(task_get_field "$task_path" TASK_INSTALLERS_REQUIRED)
optional=$(task_get_field "$task_path" TASK_INSTALLERS_OPTIONAL)
chkeq "REQUIRED empty" "$required" ""
chkeq "OPTIONAL empty" "$optional" ""

# ===========================================================================
echo
echo "=== Test 2: pick_task stage routes empty task to merge_task ==="
# Mirrors the decision tree in scripts/options.sh::pick_task that selects the
# next stage based on whether the task has required/optional installers.
next_stage_for_task() {
  local req="$1" opt="$2"
  if [[ -n $req ]]; then
    echo "show_required"
  elif [[ -n $opt ]]; then
    echo "pick_optional"
  else
    echo "merge_task"
  fi
}
chkeq "non-empty req → show_required"   "$(next_stage_for_task 'pkupd' '')"   "show_required"
chkeq "empty req, opt only → pick_optional" "$(next_stage_for_task '' 'zram')" "pick_optional"
chkeq "both empty → merge_task"         "$(next_stage_for_task '' '')"         "merge_task"

# ===========================================================================
echo
echo "=== Test 3: merge_task with no input produces empty selection ==="
# Mirrors the merge logic in scripts/options.sh::merge_task. An empty result
# is the trigger for the "nothing to do" early exit.
merge_task_selection() {
  local req="$1" opt="$2"
  local selected="$req ${opt//\"/}"
  echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//'
}
chkeq "empty req + empty opt → empty"      "$(merge_task_selection '' '')"             ""
chkeq "req only → req preserved"            "$(merge_task_selection 'pkupd rconf' '')" "pkupd rconf"
chkeq "req + opt → space-joined"            "$(merge_task_selection 'pkupd' 'zram')"   "pkupd zram"
chkeq "quoted opt has quotes stripped"      "$(merge_task_selection 'pkupd' '"zram"')" "pkupd zram"

# ===========================================================================
echo
echo "=== Test 4: empty task is a valid pick (task_list_ids picks it up) ==="
ids=$(task_list_ids "$TMPDIR" | sort | tr "\n" ",")
chkeq "task-empty.sh discovered" "$ids" "empty,"

echo
echo "=== Done ==="
