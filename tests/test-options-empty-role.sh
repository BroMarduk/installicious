#!/bin/bash
# Tests the dispatcher branches in scripts/options.sh that handle a role with
# no required AND no optional features. The decisions live inline in the
# state machine; this file mirrors the logic so we get fast unit coverage of
# the empty-role corner without driving whiptail.
#
# This is the path stubbed roles take today (homeassistant, mediaserver, pihole,
# weewx all have empty required/optional and so fall through to merge_role).

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/role.sh
source lib/manifest.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Synthetic empty role — mirrors the data shape of a manifest with no
# required and no optional features.
cat > "$TMPDIR/role-empty.sh" <<'EOF'
#!/bin/bash
# === II_ROLE_BEGIN ===
ROLE_ID="empty"
ROLE_TITLE="Empty Role"
ROLE_DESCRIPTION="No features; degenerate but supported"
ROLE_FEATURES_REQUIRED=""
ROLE_FEATURES_OPTIONAL=""
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
EOF

# ===========================================================================
echo "=== Test 1: empty-role manifest parses to empty fields ==="
role_path="$TMPDIR/role-empty.sh"
required=$(role_get_field "$role_path" ROLE_FEATURES_REQUIRED)
optional=$(role_get_field "$role_path" ROLE_FEATURES_OPTIONAL)
chkeq "REQUIRED empty" "$required" ""
chkeq "OPTIONAL empty" "$optional" ""

# ===========================================================================
echo
echo "=== Test 2: pick_role stage routes empty role to merge_role ==="
# Mirrors the decision tree in scripts/options.sh::pick_role that selects the
# next stage based on whether the role has required/optional features.
next_stage_for_role() {
  local req="$1" opt="$2"
  if [[ -n $req ]]; then
    echo "show_required"
  elif [[ -n $opt ]]; then
    echo "pick_optional"
  else
    echo "merge_role"
  fi
}
chkeq "non-empty req → show_required"        "$(next_stage_for_role 'pkupd' '')"   "show_required"
chkeq "empty req, opt only → pick_optional"  "$(next_stage_for_role '' 'zram')"    "pick_optional"
chkeq "both empty → merge_role"              "$(next_stage_for_role '' '')"        "merge_role"

# ===========================================================================
echo
echo "=== Test 3: merge_role with no input produces empty selection ==="
# Mirrors the merge logic in scripts/options.sh::merge_role. An empty result
# is the trigger for the "nothing to do" early exit.
merge_role_selection() {
  local req="$1" opt="$2"
  local selected="$req ${opt//\"/}"
  echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//'
}
chkeq "empty req + empty opt → empty"      "$(merge_role_selection '' '')"             ""
chkeq "req only → req preserved"            "$(merge_role_selection 'pkupd rconf' '')" "pkupd rconf"
chkeq "req + opt → space-joined"            "$(merge_role_selection 'pkupd' 'zram')"   "pkupd zram"
chkeq "quoted opt has quotes stripped"      "$(merge_role_selection 'pkupd' '"zram"')" "pkupd zram"

# ===========================================================================
echo
echo "=== Test 4: empty role is a valid pick (role_list_ids picks it up) ==="
ids=$(role_list_ids "$TMPDIR" | sort | tr "\n" ",")
chkeq "role-empty.sh discovered" "$ids" "empty,"

echo
echo "=== Done ==="
