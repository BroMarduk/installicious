#!/bin/bash
# Tests for lib/manifest.sh — extraction, parsing, registry helpers.
#
# Uses synthetic features in a tempdir + verifies the helpers also work
# against the real features/ + packages/ directories.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/manifest.sh

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

# ---- synthetic manifests ----
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/feature-foo.sh" <<EOF
#!/bin/bash

# === II_MANIFEST_BEGIN ===
II_ID="foo"
II_TITLE="Foo Feature"
II_CATEGORY="software"
II_VERSION="2"
II_DEPS="bar baz"
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===

# This body must NOT execute when the manifest is parsed.
echo "BODY EXECUTED — BAD" >&2
exit 99
EOF

cat > "$TMPDIR/feature-bar.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="bar"
II_TITLE="Bar Setup"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="conditional"
# === II_MANIFEST_END ===
echo "should not run"
EOF

cat > "$TMPDIR/feature-no-manifest.sh" <<EOF
#!/bin/bash
echo "no-manifest"
EOF

echo "not a manifest" > "$TMPDIR/README.txt"

# ===========================================================================
echo "=== Test 1: manifest_extract returns block content ==="
extracted=$(manifest_extract "$TMPDIR/feature-foo.sh")
echo "$extracted" | grep -q '^II_ID="foo"$' && ok "ID line present"
echo "$extracted" | grep -q '^II_TITLE="Foo Feature"$' && ok "TITLE line present"
echo "$extracted" | grep -q '^II_REQUIRES_REBOOT="never"$' && ok "REBOOT line present"
echo "$extracted" | grep -q "BODY EXECUTED" && fail "leaked body content" || ok "no body content leaked"

# ===========================================================================
echo
echo "=== Test 2: manifest_get_field for various types ==="
chkeq "ID"        "$(manifest_get_field "$TMPDIR/feature-foo.sh" II_ID)"        "foo"
chkeq "TITLE"     "$(manifest_get_field "$TMPDIR/feature-foo.sh" II_TITLE)"     "Foo Feature"
chkeq "DEPS"      "$(manifest_get_field "$TMPDIR/feature-foo.sh" II_DEPS)"      "bar baz"
chkeq "VERSION"   "$(manifest_get_field "$TMPDIR/feature-foo.sh" II_VERSION)"   "2"
chkeq "missing"   "$(manifest_get_field "$TMPDIR/feature-foo.sh" NONEXISTENT)"  ""
chkeq "no manifest" "$(manifest_get_field "$TMPDIR/feature-no-manifest.sh" II_ID)" ""

# ===========================================================================
echo
echo "=== Test 3: manifest parsing does NOT execute body ==="
out=$(manifest_get_field "$TMPDIR/feature-foo.sh" II_ID 2>&1)
[[ $out == "foo" && $out != *"BODY EXECUTED"* ]] && ok "body not executed during get_field"

# ===========================================================================
echo
echo "=== Test 4: manifest_list_files / list_ids ==="
files=$(manifest_list_files "$TMPDIR" | wc -l)
chkeq "list_files count" "$files" "3"
ids=$(manifest_list_ids "$TMPDIR" | sort | tr "\n" ",")
chkeq "list_ids skips no-manifest" "$ids" "bar,foo,"

# ===========================================================================
echo
echo "=== Test 5: manifest_path_for ==="
chkeq "path_for foo" "$(manifest_path_for foo "$TMPDIR")" "$TMPDIR/feature-foo.sh"
manifest_path_for nonexistent "$TMPDIR" >/dev/null; rc=$?
chkrc "path_for nonexistent" $rc 1

# ===========================================================================
echo
echo "=== Test 6: manifest_filter_by_category ==="
sw=$(manifest_filter_by_category software "$TMPDIR" | sort | tr "\n" ",")
chkeq "software filter" "$sw" "foo,"
op=$(manifest_filter_by_category option "$TMPDIR" | sort | tr "\n" ",")
chkeq "option filter" "$op" "bar,"
chkeq "empty filter" "$(manifest_filter_by_category nothing "$TMPDIR")" ""

# ===========================================================================
echo
echo "=== Test 7: real features/ + packages/ have the expected manifest roster ==="
real_ids=$(manifest_list_ids features packages | sort | tr "\n" ",")
chkeq "real manifests" "$real_ids" "bash,git,motd,motd-updates,motd-weather,pip,pkupd,rconf,skyfield,weewx,zram,"

# Each registered ID's filename must match feature-<id>.sh (when in features/)
# OR package-<id>.sh (when in packages/).
mismatched=""
for id in $(manifest_list_ids features packages); do
  path=$(manifest_path_for "$id" features packages)
  base=$(basename "$path" .sh)
  parent=$(basename "$(dirname "$path")")
  case "$parent" in
    features) expected="feature-$id" ;;
    packages) expected="package-$id" ;;
    *)        expected="(unexpected dir $parent)" ;;
  esac
  [[ $base == "$expected" ]] || mismatched+=" $id($base in $parent)"
done
chkeq "ID matches filename" "$mismatched" ""

# Categories partition cleanly: every registered ID is option or software, no other.
all_count=$(manifest_list_ids features packages | wc -l)
opt_count=$(manifest_filter_by_category option features packages | wc -l)
sw_count=$(manifest_filter_by_category software features packages | wc -l)
chkeq "categories partition" "$((opt_count + sw_count))" "$all_count"

# ===========================================================================
echo
echo "=== Test 8: II_OPTIONAL_GROUP — children, hidden detection ==="
# Drop a synthetic parent + child trio to exercise the helpers in isolation.
cat > "$TMPDIR/feature-parent.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="parent"
II_TITLE="Parent"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_OPTIONAL_GROUP="child-a child-b"
# === II_MANIFEST_END ===
EOF
cat > "$TMPDIR/feature-child-a.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="child-a"
II_TITLE="Child A"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
EOF
cat > "$TMPDIR/feature-child-b.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="child-b"
II_TITLE="Child B"
II_CATEGORY="software"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
EOF

children=$(manifest_optional_children_of parent "$TMPDIR")
chkeq "parent's optional children" "$children" "child-a child-b"

children=$(manifest_optional_children_of foo "$TMPDIR")
chkeq "non-parent has no children" "$children" ""

manifest_is_hidden_child child-a "$TMPDIR"; chkrc "child-a is hidden" $? 0
manifest_is_hidden_child child-b "$TMPDIR"; chkrc "child-b is hidden" $? 0
manifest_is_hidden_child parent  "$TMPDIR"; chkrc "parent is NOT hidden" $? 1
manifest_is_hidden_child foo     "$TMPDIR"; chkrc "unrelated NOT hidden" $? 1

# ===========================================================================
echo
echo "=== Test 9: real features — motd-weather is a hidden child of motd ==="
# feature-motd.sh ships with II_OPTIONAL_GROUP="motd-weather motd-updates".
# Both children should be hidden from regular category filters and the
# parent relationship must be detected.
real_children=$(manifest_optional_children_of motd features packages)
chkeq "motd's optional children" "$real_children" "motd-weather motd-updates"

manifest_is_hidden_child motd-weather features packages; chkrc "motd-weather is hidden" $? 0
manifest_is_hidden_child motd-updates features packages; chkrc "motd-updates is hidden" $? 0
manifest_is_hidden_child motd         features packages; chkrc "motd is NOT hidden"      $? 1
manifest_is_hidden_child skyfield     features packages; chkrc "skyfield is NOT hidden"  $? 1

# ===========================================================================
echo
echo "=== Test 10: defaults scan both tier directories ==="
# With no dir args, manifest helpers should hit features/ AND packages/.
# Picking IDs from each side proves both are scanned.
default_ids=$(manifest_list_ids | sort | tr "\n" ",")
chkeq "defaults match explicit two-dir scan" "$default_ids" "bash,git,motd,motd-updates,motd-weather,pip,pkupd,rconf,skyfield,weewx,zram,"

# A package ID and a feature ID both resolve to their respective dirs.
git_path=$(manifest_path_for git)
[[ "$git_path" == *packages/package-git.sh ]] && ok "package-git resolves under packages/" \
  || fail "git resolved to '$git_path'"

motd_path=$(manifest_path_for motd)
[[ "$motd_path" == *features/feature-motd.sh ]] && ok "feature-motd resolves under features/" \
  || fail "motd resolved to '$motd_path'"

echo
echo "=== Done ==="
