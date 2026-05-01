#!/bin/bash
# Tests for lib/manifest.sh — extraction, parsing, registry helpers.
#
# Uses synthetic installers in a tempdir + verifies the helpers also work
# against the real installers/ directory.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/manifest.sh

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

# ---- synthetic installers ----
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/install-foo.sh" <<EOF
#!/bin/bash

# === II_MANIFEST_BEGIN ===
II_ID="foo"
II_TITLE="Foo Installer"
II_CATEGORY="software"
II_VERSION="2"
II_DEPS="bar baz"
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===

# This body must NOT execute when the manifest is parsed.
echo "BODY EXECUTED — BAD" >&2
exit 99
EOF

cat > "$TMPDIR/install-bar.sh" <<EOF
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

cat > "$TMPDIR/install-no-manifest.sh" <<EOF
#!/bin/bash
echo "no-manifest"
EOF

echo "not an installer" > "$TMPDIR/README.txt"

# ===========================================================================
echo "=== Test 1: manifest_extract returns block content ==="
extracted=$(manifest_extract "$TMPDIR/install-foo.sh")
echo "$extracted" | grep -q '^II_ID="foo"$' && ok "ID line present"
echo "$extracted" | grep -q '^II_TITLE="Foo Installer"$' && ok "TITLE line present"
echo "$extracted" | grep -q '^II_REQUIRES_REBOOT="never"$' && ok "REBOOT line present"
echo "$extracted" | grep -q "BODY EXECUTED" && fail "leaked body content" || ok "no body content leaked"

# ===========================================================================
echo
echo "=== Test 2: manifest_get_field for various types ==="
chkeq "ID"        "$(manifest_get_field "$TMPDIR/install-foo.sh" II_ID)"        "foo"
chkeq "TITLE"     "$(manifest_get_field "$TMPDIR/install-foo.sh" II_TITLE)"     "Foo Installer"
chkeq "DEPS"      "$(manifest_get_field "$TMPDIR/install-foo.sh" II_DEPS)"      "bar baz"
chkeq "VERSION"   "$(manifest_get_field "$TMPDIR/install-foo.sh" II_VERSION)"   "2"
chkeq "missing"   "$(manifest_get_field "$TMPDIR/install-foo.sh" NONEXISTENT)"  ""
chkeq "no manifest" "$(manifest_get_field "$TMPDIR/install-no-manifest.sh" II_ID)" ""

# ===========================================================================
echo
echo "=== Test 3: manifest parsing does NOT execute installer body ==="
out=$(manifest_get_field "$TMPDIR/install-foo.sh" II_ID 2>&1)
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
chkeq "path_for foo" "$(manifest_path_for foo "$TMPDIR")" "$TMPDIR/install-foo.sh"
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
echo "=== Test 7: real installers/ directory has 5 valid manifests ==="
real_ids=$(manifest_list_ids installers | sort | tr "\n" ",")
chkeq "real installers" "$real_ids" "bash,git,pip,pkupd,rconf,zram,"

# Each registered ID must point to its own install-<id>.sh file.
mismatched=""
for id in $(manifest_list_ids installers); do
  path=$(manifest_path_for "$id" installers)
  base=$(basename "$path" .sh)
  expected="install-$id"
  [[ $base == "$expected" ]] || mismatched+=" $id($base)"
done
chkeq "ID matches filename" "$mismatched" ""

# Categories partition cleanly: every registered ID is option or software, no other.
all_count=$(manifest_list_ids installers | wc -l)
opt_count=$(manifest_filter_by_category option installers | wc -l)
sw_count=$(manifest_filter_by_category software installers | wc -l)
chkeq "categories partition" "$((opt_count + sw_count))" "$all_count"

echo
echo "=== Done ==="
