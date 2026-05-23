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
II_CATEGORY="package"
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
II_CATEGORY="feature"
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
sw=$(manifest_filter_by_category package "$TMPDIR" | sort | tr "\n" ",")
chkeq "feature filter" "$sw" "foo,"
op=$(manifest_filter_by_category feature "$TMPDIR" | sort | tr "\n" ",")
chkeq "package filter" "$op" "bar,"
chkeq "empty filter" "$(manifest_filter_by_category nothing "$TMPDIR")" ""

# ===========================================================================
echo
echo "=== Test 7: real features/ + packages/ have the expected manifest roster ==="
real_ids=$(manifest_list_ids features packages | sort | tr "\n" ",")
chkeq "real manifests" "$real_ids" "apache,bash,caddy,compressed-swap,database,database-mysql,database-sqlite,git,jshon,lighttpd,locale,log2ram,motd,motd-updates,motd-weather,neowx-material,nginx,pip,pkupd,ram-logging,rconf,skyfield,webserver,webserver-ssl,webserver-under-construction,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,weewx-site-ram,weewx-webroot,zram,"

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

# Categories partition cleanly: every registered ID is feature or package, no other.
all_count=$(manifest_list_ids features packages | wc -l)
opt_count=$(manifest_filter_by_category feature features packages | wc -l)
sw_count=$(manifest_filter_by_category package features packages | wc -l)
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
II_CATEGORY="feature"
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
II_CATEGORY="feature"
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
II_CATEGORY="package"
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

# Web server backends are hidden children of the webserver parent.
ws_children=$(manifest_optional_children_of webserver features packages)
chkeq "webserver's optional children" "$ws_children" "nginx apache lighttpd caddy"
manifest_is_hidden_child nginx    features packages; chkrc "nginx is hidden child"    $? 0
manifest_is_hidden_child apache   features packages; chkrc "apache is hidden child"   $? 0
manifest_is_hidden_child lighttpd features packages; chkrc "lighttpd is hidden child" $? 0
manifest_is_hidden_child caddy    features packages; chkrc "caddy is hidden child"    $? 0
manifest_is_hidden_child webserver features packages; chkrc "webserver is NOT hidden" $? 1

# Each backend declares its own II_OPTIONAL_GROUP for the post-radio
# sub-features. nginx / apache / lighttpd offer under-construction +
# ssl; caddy offers only under-construction (auto-HTTPS).
nginx_children=$(manifest_optional_children_of nginx features packages)
apache_children=$(manifest_optional_children_of apache features packages)
lighttpd_children=$(manifest_optional_children_of lighttpd features packages)
caddy_children=$(manifest_optional_children_of caddy features packages)
chkeq "nginx's optional children"    "$nginx_children"    "webserver-under-construction webserver-ssl"
chkeq "apache's optional children"   "$apache_children"   "webserver-under-construction webserver-ssl"
chkeq "lighttpd's optional children" "$lighttpd_children" "webserver-under-construction webserver-ssl"
chkeq "caddy's optional children"    "$caddy_children"    "webserver-under-construction"

# under-construction is a hidden child (of all four backends).
manifest_is_hidden_child webserver-under-construction features packages; chkrc "under-construction is hidden child" $? 0
# ssl is a hidden child too (of nginx/apache/lighttpd; not caddy).
manifest_is_hidden_child webserver-ssl                features packages; chkrc "ssl is hidden child" $? 0

# ===========================================================================
echo
echo "=== Test 10: defaults scan both tier directories ==="
# With no dir args, manifest helpers should hit features/ AND packages/.
# Picking IDs from each side proves both are scanned.
default_ids=$(manifest_list_ids | sort | tr "\n" ",")
chkeq "defaults match explicit two-dir scan" "$default_ids" "apache,bash,caddy,compressed-swap,database,database-mysql,database-sqlite,git,jshon,lighttpd,locale,log2ram,motd,motd-updates,motd-weather,neowx-material,nginx,pip,pkupd,ram-logging,rconf,skyfield,webserver,webserver-ssl,webserver-under-construction,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,weewx-site-ram,weewx-webroot,zram,"

# Web server visibility gate: backends are restricted to webserver + weewx.
manifest_is_visible_for_role nginx    webserver; chkrc "nginx visible under webserver"   $? 0
manifest_is_visible_for_role nginx    weewx;     chkrc "nginx visible under weewx"       $? 0
manifest_is_visible_for_role nginx    custom;    chkrc "nginx hidden under custom"       $? 1
manifest_is_visible_for_role apache   pihole;    chkrc "apache hidden under pihole"      $? 1
manifest_is_visible_for_role lighttpd webserver; chkrc "lighttpd visible under webserver" $? 0
manifest_is_visible_for_role caddy    weewx;     chkrc "caddy visible under weewx"       $? 0

# II_OPTIONAL_GROUP_MODE round-trips for the parent.
ws_path=$(manifest_path_for webserver)
chkeq "webserver mode" "$(manifest_get_field "$ws_path" II_OPTIONAL_GROUP_MODE)" "exclusive"
# Other parents (motd) don't set the mode -> empty string (legacy multi-select).
motd_mode_path=$(manifest_path_for motd)
chkeq "motd mode (empty=multi)" "$(manifest_get_field "$motd_mode_path" II_OPTIONAL_GROUP_MODE)" ""

# A package ID and a feature ID both resolve to their respective dirs.
git_path=$(manifest_path_for git)
[[ "$git_path" == *packages/package-git.sh ]] && ok "package-git resolves under packages/" \
  || fail "git resolved to '$git_path'"

motd_path=$(manifest_path_for motd)
[[ "$motd_path" == *features/feature-motd.sh ]] && ok "feature-motd resolves under features/" \
  || fail "motd resolved to '$motd_path'"

# ===========================================================================
echo
echo "=== Test 11: manifest_is_visible_for_role — II_RESTRICT_TO_ROLES gate ==="
# Synthetic feature with a role restriction.
cat > "$TMPDIR/feature-restricted.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="restricted"
II_TITLE="Restricted Feature"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_RESTRICT_TO_ROLES="weewx"
# === II_MANIFEST_END ===
EOF

manifest_is_visible_for_role restricted weewx   "$TMPDIR"; chkrc "weewx sees restricted"             $? 0
manifest_is_visible_for_role restricted custom  "$TMPDIR"; chkrc "custom hides restricted"           $? 1
manifest_is_visible_for_role restricted pihole  "$TMPDIR"; chkrc "pihole hides restricted"           $? 1
manifest_is_visible_for_role foo        custom  "$TMPDIR"; chkrc "unrestricted foo visible (custom)" $? 0
manifest_is_visible_for_role nonexistent custom "$TMPDIR"; chkrc "missing id treated as visible"     $? 0

# Multi-role restriction: each listed role sees it, others don't.
cat > "$TMPDIR/feature-multi.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="multi"
II_TITLE="Multi-role Feature"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_RESTRICT_TO_ROLES="weewx homeassistant"
# === II_MANIFEST_END ===
EOF

manifest_is_visible_for_role multi weewx         "$TMPDIR"; chkrc "multi visible for weewx"         $? 0
manifest_is_visible_for_role multi homeassistant "$TMPDIR"; chkrc "multi visible for homeassistant" $? 0
manifest_is_visible_for_role multi custom        "$TMPDIR"; chkrc "multi hidden for custom"         $? 1

# Real-tree check: skyfield is restricted to the weewx role.
manifest_is_visible_for_role skyfield weewx;  chkrc "real skyfield visible under weewx" $? 0
manifest_is_visible_for_role skyfield custom; chkrc "real skyfield hidden under custom" $? 1
manifest_is_visible_for_role skyfield pihole; chkrc "real skyfield hidden under pihole" $? 1
# Unrestricted features should be visible regardless of role.
manifest_is_visible_for_role bash     custom; chkrc "real bash visible under custom"    $? 0
manifest_is_visible_for_role git      pihole; chkrc "real git visible under pihole"     $? 0

# ===========================================================================
echo
echo "=== Test 12: II_CONFLICTS_WITH — bidirectional conflict detection ==="
# Synthetic conflict pair: A declares conflict with B; B says nothing.
# The check must fire either way (caller doesn't know which side declared).
cat > "$TMPDIR/feature-side-a.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="side-a"
II_TITLE="Side A"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_CONFLICTS_WITH="side-b"
# === II_MANIFEST_END ===
EOF
cat > "$TMPDIR/feature-side-b.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="side-b"
II_TITLE="Side B"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
EOF
cat > "$TMPDIR/feature-side-c.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="side-c"
II_TITLE="Side C"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
EOF

# Direct-dir-arg form (no registry pollution).
chkeq "side-a's conflicts"    "$(manifest_get_conflicts side-a "$TMPDIR")" "side-b"
chkeq "side-b's conflicts"    "$(manifest_get_conflicts side-b "$TMPDIR")" ""
chkeq "side-c's conflicts"    "$(manifest_get_conflicts side-c "$TMPDIR")" ""
chkeq "no-such-id conflicts"  "$(manifest_get_conflicts nope    "$TMPDIR")" ""

# manifest_is_in_conflict_with uses the cached registry under the hood — point
# it at TMPDIR for this block, then point it back at the real tree for the
# real-tree assertions below.
PATH_FEATURES="$TMPDIR" PATH_PACKAGES="$TMPDIR"
_MANIFEST_BLOCK=(); _MANIFEST_FIELDS=(); _MANIFEST_FILES=(); _MANIFEST_IDS=(); _MANIFEST_PATH=(); _MANIFEST_LOADED=0
_manifest_registry_load

manifest_is_in_conflict_with side-a side-b
chkrc "A conflicts with B (A declared)" $? 0
manifest_is_in_conflict_with side-b side-a
chkrc "B conflicts with A (via A's decl)" $? 0
manifest_is_in_conflict_with side-c side-a
chkrc "C does not conflict with A"        $? 1
manifest_is_in_conflict_with side-a side-c
chkrc "A does not conflict with C"        $? 1
# Self never reports as conflict.
manifest_is_in_conflict_with side-a side-a
chkrc "self is not a conflict"            $? 1
# Multi-id queue: matches if ANY queued id conflicts.
manifest_is_in_conflict_with side-a side-c side-b
chkrc "A conflicts when B is anywhere in queue" $? 0
manifest_is_in_conflict_with side-a side-c side-c
chkrc "A does not conflict on a c-only queue"   $? 1

# Real-tree check: weewx-site-ram and webserver-under-construction declare a
# mutual conflict via II_CONFLICTS_WITH (they fight for WEEWX_WEB_DIR/index.html).
PATH_FEATURES="features" PATH_PACKAGES="packages"
_MANIFEST_BLOCK=(); _MANIFEST_FIELDS=(); _MANIFEST_FILES=(); _MANIFEST_IDS=(); _MANIFEST_PATH=(); _MANIFEST_LOADED=0
_manifest_registry_load

manifest_is_in_conflict_with weewx-site-ram webserver-under-construction
chkrc "real site-ram blocked by under-construction" $? 0
manifest_is_in_conflict_with webserver-under-construction weewx-site-ram
chkrc "real under-construction blocked by site-ram" $? 0
manifest_is_in_conflict_with weewx-site-ram motd
chkrc "real site-ram not in conflict with motd"     $? 1

echo
echo "=== Done ==="
