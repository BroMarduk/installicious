#!/bin/bash
# Tests the dispatcher branches in scripts/options.sh that handle a role with
# no required AND no optional features. The decisions live inline in the
# state machine; this file mirrors the logic so we get fast unit coverage of
# the empty-role corner without driving whiptail.
#
# This is the path stubbed roles take today (homeassistant, mediaserver,
# pihole have empty required/optional and so flow through the
# Custom-style per-feature picker — they "behave like Custom" until they
# grow real feature lists). The weewx role used to be in this group but
# has since been populated with REQUIRED + DEFAULT + OPTIONAL tiers, so
# it no longer takes the empty-role path at runtime.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/role.sh
source lib/manifest.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

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
ROLE_FEATURES_DEFAULT=""
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
echo "=== Test 2: pick_role stage routes empty role to custom_options ==="
# Mirrors the decision tree in scripts/options.sh::pick_role that selects the
# next stage based on whether the role has required / default / optional
# features. A role with all three empty falls through to custom_options
# (the per-feature picker) — same flow Custom uses.
next_stage_for_role() {
  local req="$1" def="$2" opt="$3"
  if [[ -n $req ]]; then
    echo "show_required"
  elif [[ -n $def || -n $opt ]]; then
    echo "pick_optional"
  else
    echo "custom_options"
  fi
}
chkeq "non-empty req → show_required"           "$(next_stage_for_role 'pkupd' ''       '')"     "show_required"
chkeq "default only → pick_optional"             "$(next_stage_for_role ''      'locale' '')"     "pick_optional"
chkeq "optional only → pick_optional"            "$(next_stage_for_role ''      ''       'zram')" "pick_optional"
chkeq "default + optional → pick_optional"       "$(next_stage_for_role ''      'locale' 'zram')" "pick_optional"
chkeq "all empty → custom_options"               "$(next_stage_for_role ''      ''       '')"     "custom_options"

# ===========================================================================
echo
echo "=== Test 3: _role_uses_custom_flow predicate ==="
# Mirrors the helper in scripts/options.sh used by prev_selection_stage and
# _pre_addons_stage. Returns true (rc=0) for Custom OR any role with all
# three feature lists empty.
role_uses_custom_flow() {
  local role_id="$1" req="$2" def="$3" opt="$4"
  [[ $role_id == "custom" ]] && return 0
  [[ -z $req && -z $def && -z $opt ]] && return 0
  return 1
}
role_uses_custom_flow "custom" ""      ""       "";     chkrc "custom always true"            $? 0
role_uses_custom_flow "weewx"  ""      ""       "";     chkrc "stubbed (all empty) true"      $? 0
role_uses_custom_flow "weewx"  "pkupd" ""       "";     chkrc "non-empty req → false"         $? 1
role_uses_custom_flow "weewx"  ""      "locale" "";     chkrc "non-empty default → false"     $? 1
role_uses_custom_flow "weewx"  ""      ""       "zram"; chkrc "non-empty optional → false"    $? 1
role_uses_custom_flow "weewx"  "pkupd" "locale" "zram"; chkrc "all three populated → false"   $? 1

# ===========================================================================
echo
echo "=== Test 4: empty role is a valid pick (role_list_ids picks it up) ==="
ids=$(role_list_ids "$TMPDIR" | sort | tr "\n" ",")
chkeq "role-empty.sh discovered" "$ids" "empty,"

echo
echo "=== Done ==="
