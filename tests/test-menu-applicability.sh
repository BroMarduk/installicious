#!/bin/bash
# Tests for the per-installer choices file + menu_key_applicable mechanism
# in lib/menu.sh. Uses a synthetic installer (created in a tempdir) rather
# than testing against any real installer's choices file — that keeps the
# test independent of which installers happen to ship with installicious.
#
# Why this matters: an editable key whose _applies_/_choices_ helper rejects
# the current system must be HIDDEN from the menu AND its config value must
# be IGNORED at install time. This suite locks both ends of that contract.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/manifest.sh
source lib/menu.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ===========================================================================
echo "=== Test 1: menu_key_applicable with neither helper → applicable ==="
unset -f _applies_TEST_KEY _choices_TEST_KEY 2>/dev/null
menu_key_applicable TEST_KEY; chkrc "no helpers → rc=0" $? 0

# ===========================================================================
echo
echo "=== Test 2: _applies_<KEY> takes precedence over _choices_<KEY> ==="
_applies_K1() { return 1; }      # not applicable
_choices_K1() { echo "x"; }      # would say applicable
menu_key_applicable K1; chkrc "applies says no → rc=1" $? 1
unset -f _applies_K1 _choices_K1

# ===========================================================================
echo
echo "=== Test 3: empty _choices_<KEY> → not applicable ==="
_choices_K2() { return 0; }       # echo nothing
menu_key_applicable K2; chkrc "empty choices → rc=1" $? 1
unset -f _choices_K2

# ===========================================================================
echo
echo "=== Test 4: non-empty _choices_<KEY> → applicable ==="
_choices_K3() { echo -e "yes\tYes"; echo -e "no\tNo"; }
menu_key_applicable K3; chkrc "non-empty choices → rc=0" $? 0
unset -f _choices_K3

# ===========================================================================
echo
echo "=== Test 5: synthetic feature choices file — Pi-version gating ==="
# Drop a fake feature manifest + sibling choices file into a tempdir and
# source-load it the same way menu_edit_config does in production.
# _menu_source_choices_for derives the choices path from the manifest's
# location, so a real manifest needs to exist next to the choices file.
mkdir -p "$TMPDIR/features"
cat > "$TMPDIR/features/feature-foo.sh" <<'EOF'
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="foo"
II_TITLE="Foo (synthetic)"
II_CATEGORY="option"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
EOF
cat > "$TMPDIR/features/feature-foo.choices.sh" <<'EOF'
# Synthetic choices file — exercises common gating patterns.

# Always-applicable enumerated key.
_choices_FOO_BOOL() {
  cat <<INNER
true	Yes
false	No
INNER
}

# Pi 4/5-only enumerated key.
_choices_FOO_PI4_PLUS() {
  if [[ ${II_MODEL_NUM:-0} -ge 4 ]]; then
    cat <<INNER
on	Enable
off	Disable
INNER
  fi
}

# Pi 5-only enumerated key.
_choices_FOO_PI5_ONLY() {
  if [[ ${II_MODEL_NUM:-0} -eq 5 ]]; then
    cat <<INNER
yes	Yes
no	No
INNER
  fi
}

# Lite-vs-Full conditional choices — Lite restricts the available options.
_choices_FOO_LITE_AWARE() {
  if [[ ${II_IS_LITE:-true} == "true" ]]; then
    echo -e "console\tConsole only (Lite)"
  else
    cat <<INNER
console	Console
desktop	Desktop
INNER
  fi
}

# Free-form key with a Pi-4-only applicability gate.
_applies_FOO_FREE_PI4() {
  [[ ${II_MODEL_NUM:-0} -eq 4 ]]
}
EOF

# Use _menu_source_choices_for to load it, exactly as menu_edit_config does.
# Override PATH_FEATURES + PATH_PACKAGES so manifest_path_for finds our synthetic
# feature-foo.sh (manifest_path_for is what _menu_source_choices_for uses to
# locate the sibling .choices.sh file).
PATH_FEATURES="$TMPDIR/features" PATH_PACKAGES="$TMPDIR/features" \
  _menu_source_choices_for "foo"
declare -F _choices_FOO_BOOL >/dev/null && ok "synthetic choices loaded (FOO_BOOL)" \
  || fail "_menu_source_choices_for did not load synthetic file"

# Pi 5 case
II_MODEL_NUM=5 II_CODENAME="Trixie" II_IS_LITE="true"
menu_key_applicable FOO_BOOL;       chkrc "Pi 5: always-applicable bool" $? 0
menu_key_applicable FOO_PI4_PLUS;   chkrc "Pi 5: pi4+ key applicable"    $? 0
menu_key_applicable FOO_PI5_ONLY;   chkrc "Pi 5: pi5-only applicable"    $? 0
menu_key_applicable FOO_FREE_PI4;   chkrc "Pi 5: free pi4-only NOT applicable" $? 1

# Pi 4 case
II_MODEL_NUM=4
menu_key_applicable FOO_PI4_PLUS;   chkrc "Pi 4: pi4+ applicable"        $? 0
menu_key_applicable FOO_PI5_ONLY;   chkrc "Pi 4: pi5-only NOT applicable" $? 1
menu_key_applicable FOO_FREE_PI4;   chkrc "Pi 4: free pi4-only applicable" $? 0

# Pi 3 case
II_MODEL_NUM=3
menu_key_applicable FOO_PI4_PLUS;   chkrc "Pi 3: pi4+ NOT applicable"    $? 1
menu_key_applicable FOO_PI5_ONLY;   chkrc "Pi 3: pi5-only NOT applicable" $? 1
menu_key_applicable FOO_FREE_PI4;   chkrc "Pi 3: free pi4-only NOT applicable" $? 1
menu_key_applicable FOO_BOOL;       chkrc "Pi 3: always-applicable bool" $? 0

# Pi Zero (model 0)
II_MODEL_NUM=0
menu_key_applicable FOO_PI4_PLUS;   chkrc "Pi Zero: pi4+ NOT applicable" $? 1

# ===========================================================================
echo
echo "=== Test 6: Lite vs Full gating returns different choice sets ==="
II_MODEL_NUM=4 II_CODENAME="Bookworm" II_IS_LITE="true"
lite_choices=$(_choices_FOO_LITE_AWARE)
chkeq "Lite: 1 line in choices" \
  "$(echo "$lite_choices" | wc -l | tr -d ' ')" "1"
echo "$lite_choices" | grep -q "^console" && ok "Lite: 'console' present" \
  || fail "Lite: 'console' missing"

II_IS_LITE="false"
full_choices=$(_choices_FOO_LITE_AWARE)
chkeq "Full: 2 lines in choices" \
  "$(echo "$full_choices" | wc -l | tr -d ' ')" "2"
echo "$full_choices" | grep -q "^desktop" && ok "Full: 'desktop' present" \
  || fail "Full: 'desktop' missing"

# ===========================================================================
echo
echo "=== Test 7: choices output format — value<TAB>label ==="
II_MODEL_NUM=4 II_IS_LITE="true"
first_line=$(_choices_FOO_PI4_PLUS | head -1)
[[ $first_line == *$'\t'* ]] && ok "format includes tab separator" \
  || fail "missing tab in '$first_line'"
val="${first_line%%$'\t'*}"
label="${first_line#*$'\t'}"
chkeq "first value is 'on'"      "$val"   "on"
chkeq "first label is 'Enable'"  "$label" "Enable"

# ===========================================================================
echo
echo "=== Test 8: _menu_source_choices_for is a no-op for missing files ==="
unset -f _choices_FOO_BOOL 2>/dev/null
declare -F _choices_FOO_BOOL >/dev/null && fail "stale function not unset" \
  || ok "function unset (precondition)"

# An ID with no manifest entry shouldn't error or define functions.
PATH_FEATURES="$TMPDIR/features" PATH_PACKAGES="$TMPDIR/features" \
  _menu_source_choices_for "nonexistent-feature"
declare -F _choices_NONEXISTENT >/dev/null && fail "function unexpectedly defined" \
  || ok "no function defined when manifest is missing"

# Re-loading the foo file restores its functions.
PATH_FEATURES="$TMPDIR/features" PATH_PACKAGES="$TMPDIR/features" \
  _menu_source_choices_for "foo"
declare -F _choices_FOO_BOOL >/dev/null && ok "function reloaded after second source" \
  || fail "function not reloaded"

echo
echo "=== Done ==="
