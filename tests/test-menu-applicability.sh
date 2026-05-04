#!/bin/bash
# Tests for the per-installer choices file + menu_key_applicable mechanism
# in lib/menu.sh, plus the install-rconf.choices.sh helper functions on
# specific (Pi model, OS, Lite/Full) tuples.
#
# Why this matters: an editable key whose _applies_/_choices_ helper rejects
# the current system must be HIDDEN from the menu AND its config value must
# be IGNORED at install time. This suite locks both ends of that contract.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/menu.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

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
echo "=== Test 5: install-rconf.choices.sh — Pi-version gating ==="
# Source the real choices file and exercise it under simulated detection.
source installers/install-rconf.choices.sh

# Pi 5 case
II_MODEL_NUM=5 II_CODENAME="Trixie" II_IS_LITE="true"
menu_key_applicable RCONF_USB_CURRENT_UNLIMITED; chkrc "Pi 5: USB current applicable" $? 0
menu_key_applicable RCONF_BOOT_ORDER;             chkrc "Pi 5: boot order applicable" $? 0
menu_key_applicable RCONF_BOOTLOADER_VERSION;     chkrc "Pi 5: bootloader version applicable" $? 0
menu_key_applicable RCONF_FAN_ENABLE;             chkrc "Pi 5: fan enable NOT applicable (Pi 4 only)" $? 1
menu_key_applicable RCONF_OVERCLOCK;              chkrc "Pi 5: overclock NOT applicable (Pi 1/2 only)" $? 1

# Pi 4 case
II_MODEL_NUM=4 II_CODENAME="Bookworm" II_IS_LITE="true"
menu_key_applicable RCONF_USB_CURRENT_UNLIMITED; chkrc "Pi 4: USB current NOT applicable (Pi 5 only)" $? 1
menu_key_applicable RCONF_BOOT_ORDER;             chkrc "Pi 4: boot order applicable" $? 0
menu_key_applicable RCONF_FAN_ENABLE;             chkrc "Pi 4: fan enable applicable" $? 0
menu_key_applicable RCONF_FAN_GPIO;               chkrc "Pi 4: fan GPIO applicable (free-form, _applies_)" $? 0

# Pi 3 case
II_MODEL_NUM=3 II_CODENAME="Bookworm" II_IS_LITE="true"
menu_key_applicable RCONF_BOOT_ORDER;             chkrc "Pi 3: boot order NOT applicable" $? 1
menu_key_applicable RCONF_BOOTLOADER_VERSION;     chkrc "Pi 3: bootloader version NOT applicable" $? 1
menu_key_applicable RCONF_USB_CURRENT_UNLIMITED; chkrc "Pi 3: USB current NOT applicable" $? 1
menu_key_applicable RCONF_FAN_ENABLE;             chkrc "Pi 3: fan enable NOT applicable" $? 1
menu_key_applicable RCONF_OVERCLOCK;              chkrc "Pi 3: overclock NOT applicable" $? 1
menu_key_applicable RCONF_INTERFACE_I2C;          chkrc "Pi 3: I2C applicable (works on all Pis)" $? 0

# Pi 1
II_MODEL_NUM=1 II_CODENAME="Bookworm" II_IS_LITE="true"
menu_key_applicable RCONF_OVERCLOCK;              chkrc "Pi 1: overclock applicable" $? 0
menu_key_applicable RCONF_BOOT_ORDER;             chkrc "Pi 1: boot order NOT applicable" $? 1

# ===========================================================================
echo
echo "=== Test 6: install-rconf.choices.sh — Lite vs Full boot-target gating ==="
# When Lite, only "console" is offered. When Full, both options are offered.
II_MODEL_NUM=4 II_CODENAME="Bookworm" II_IS_LITE="true"
lite_choices=$(_choices_RCONF_BOOT_TARGET)
chkeq "Lite: only 'console' offered (1 line)" \
  "$(echo "$lite_choices" | wc -l | tr -d ' ')" "1"
echo "$lite_choices" | grep -q "^console" && ok "Lite: 'console' is in the choices" \
  || fail "Lite: 'console' missing from choices"

II_IS_LITE="false"
full_choices=$(_choices_RCONF_BOOT_TARGET)
chkeq "Full: both options (2 lines)" \
  "$(echo "$full_choices" | wc -l | tr -d ' ')" "2"
echo "$full_choices" | grep -q "^desktop" && ok "Full: 'desktop' is in the choices" \
  || fail "Full: 'desktop' missing from choices"

# ===========================================================================
echo
echo "=== Test 7: choices output format — value<TAB>label ==="
II_MODEL_NUM=5 II_CODENAME="Trixie" II_IS_LITE="true"
first_line=$(_choices_RCONF_BOOT_ORDER | head -1)
[[ $first_line == *$'\t'* ]] && ok "boot order: format includes tab separator" \
  || fail "boot order: missing tab in '$first_line'"
val="${first_line%%$'\t'*}"
label="${first_line#*$'\t'}"
chkeq "boot order: first value is 0xf41" "$val" "0xf41"
[[ -n $label && $label != "$val" ]] && ok "boot order: first label is non-empty and distinct" \
  || fail "boot order: label not separable from value"

# ===========================================================================
echo
echo "=== Test 8: _menu_source_choices_for sources the right file ==="
unset -f _choices_RCONF_BOOT_ORDER 2>/dev/null
declare -F _choices_RCONF_BOOT_ORDER >/dev/null && fail "stale function not unset" \
  || ok "function unset (precondition)"

_menu_source_choices_for "rconf"
declare -F _choices_RCONF_BOOT_ORDER >/dev/null && ok "function loaded after _menu_source_choices_for" \
  || fail "function not loaded after sourcing"

# Sourcing for an installer with no choices file is a no-op.
_menu_source_choices_for "nonexistent-installer"
ok "_menu_source_choices_for no-op for missing file"

echo
echo "=== Done ==="
