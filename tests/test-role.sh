#!/bin/bash
# Tests for lib/role.sh — extraction, parsing, registry helpers.
# Mirrors test-manifest.sh's structure; uses synthetic roles in a tempdir
# plus sanity-checks against the real roles/ directory.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/role.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/role-foo.sh" <<'EOF'
#!/bin/bash
# === II_ROLE_BEGIN ===
ROLE_ID="foo"
ROLE_TITLE="Foo Role"
ROLE_DESCRIPTION="A pretend role"
ROLE_FEATURES_REQUIRED="alpha beta"
ROLE_FEATURES_OPTIONAL="gamma"
ROLE_CONFIG="config/role-foo.config"
ROLE_EDITABLE_CONFIG="FOO_HOSTNAME"
# === II_ROLE_END ===
echo "BODY EXECUTED — BAD" >&2
exit 99
EOF

cat > "$TMPDIR/role-bar.sh" <<'EOF'
#!/bin/bash
# === II_ROLE_BEGIN ===
ROLE_ID="bar"
ROLE_TITLE="Bar Role"
ROLE_DESCRIPTION="Another pretend role"
ROLE_FEATURES_REQUIRED=""
ROLE_FEATURES_OPTIONAL=""
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
echo "should not run"
EOF

cat > "$TMPDIR/role-no-manifest.sh" <<'EOF'
#!/bin/bash
echo "no-manifest role"
EOF

# A non-role file should be ignored.
echo "not a role" > "$TMPDIR/README.txt"

# ===========================================================================
echo "=== Test 1: role_extract returns block content ==="
extracted=$(role_extract "$TMPDIR/role-foo.sh")
echo "$extracted" | grep -q '^ROLE_ID="foo"$'                            && ok "ID line present"
echo "$extracted" | grep -q '^ROLE_TITLE="Foo Role"$'                    && ok "TITLE line present"
echo "$extracted" | grep -q '^ROLE_FEATURES_REQUIRED="alpha beta"$'      && ok "REQUIRED line present"
echo "$extracted" | grep -q "BODY EXECUTED" && fail "leaked body content" || ok "no body content leaked"

# ===========================================================================
echo
echo "=== Test 2: role_get_field for various types ==="
chkeq "ID"          "$(role_get_field "$TMPDIR/role-foo.sh" ROLE_ID)"                "foo"
chkeq "TITLE space" "$(role_get_field "$TMPDIR/role-foo.sh" ROLE_TITLE)"             "Foo Role"
chkeq "REQUIRED"    "$(role_get_field "$TMPDIR/role-foo.sh" ROLE_FEATURES_REQUIRED)" "alpha beta"
chkeq "OPTIONAL"    "$(role_get_field "$TMPDIR/role-foo.sh" ROLE_FEATURES_OPTIONAL)" "gamma"
chkeq "missing"     "$(role_get_field "$TMPDIR/role-foo.sh" NONEXISTENT)"            ""
chkeq "no manifest" "$(role_get_field "$TMPDIR/role-no-manifest.sh" ROLE_ID)"        ""

# ===========================================================================
echo
echo "=== Test 3: parsing does NOT execute role body ==="
out=$(role_get_field "$TMPDIR/role-foo.sh" ROLE_ID 2>&1)
[[ $out == "foo" && $out != *"BODY EXECUTED"* ]] && ok "body not executed during get_field"

# ===========================================================================
echo
echo "=== Test 4: role_list_files / list_ids ==="
files=$(role_list_files "$TMPDIR" | wc -l)
chkeq "list_files count (3 role-*.sh files)" "$files" "3"
ids=$(role_list_ids "$TMPDIR" | sort | tr "\n" ",")
chkeq "list_ids skips no-manifest" "$ids" "bar,foo,"

# ===========================================================================
echo
echo "=== Test 5: role_path_for ==="
chkeq "path_for foo" "$(role_path_for foo "$TMPDIR")" "$TMPDIR/role-foo.sh"
role_path_for nonexistent "$TMPDIR" >/dev/null; rc=$?
chkrc "path_for nonexistent rc=1" $rc 1

# ===========================================================================
echo
echo "=== Test 6: real roles/ directory has the expected starter set ==="
real_ids=$(role_list_ids roles | sort | tr "\n" ",")
chkeq "real roles discovered" "$real_ids" "custom,homeassistant,mediaserver,pihole,weewx,"

# Each registered ID must point to its own role-<id>.sh file.
mismatched=""
for id in $(role_list_ids roles); do
  path=$(role_path_for "$id" roles)
  base=$(basename "$path" .sh)
  expected="role-$id"
  [[ $base == "$expected" ]] || mismatched+=" $id($base)"
done
chkeq "ID matches filename" "$mismatched" ""

# Custom role is the special fallthrough — verify its required/optional lists
# are empty (the menu logic relies on this).
chkeq "custom has no required" "$(role_get_field "$(role_path_for custom roles)" ROLE_FEATURES_REQUIRED)" ""
chkeq "custom has no optional" "$(role_get_field "$(role_path_for custom roles)" ROLE_FEATURES_OPTIONAL)" ""

# Stubbed roles (homeassistant, mediaserver, pihole, weewx) currently behave
# like Custom — empty required/optional. They'll grow real feature lists when
# the features tier lands. Until then, assert they parse cleanly with empty
# lists so a regression that drops the manifest sentinel gets caught here.
for id in homeassistant mediaserver pihole weewx; do
  path=$(role_path_for "$id" roles)
  if [[ -z $path ]]; then
    fail "stubbed role $id: no path resolved"
    continue
  fi
  req=$(role_get_field "$path" ROLE_FEATURES_REQUIRED)
  opt=$(role_get_field "$path" ROLE_FEATURES_OPTIONAL)
  title=$(role_get_field "$path" ROLE_TITLE)
  [[ -z $req && -z $opt && -n $title ]] \
    && ok "stubbed role $id: empty required/optional, title set" \
    || fail "stubbed role $id: req='$req' opt='$opt' title='$title'"
done

echo
echo "=== Done ==="
