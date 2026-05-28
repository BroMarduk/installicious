#!/bin/bash
# Tests for lib/detect.sh — Pi-model + Pi-Zero detection from /proc/cpuinfo.
# Drives the helpers with synthetic cpuinfo files so we don't depend on the
# test runner's own hardware.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/detect.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# mk_cpuinfo <name> <model_line>
# Drops a synthetic /proc/cpuinfo-shaped file with just the Model line set.
mk_cpuinfo() {
  local name="$1" model="$2"
  cat > "$TMPDIR/cpuinfo-$name" <<EOF
processor       : 0
BogoMIPS        : 108.00
Hardware        : BCM2835
Revision        : 000000
Serial          : 0000000000000000
Model           : $model
EOF
}

# ===========================================================================
echo "=== Test 1: Pi 5 detection ==="
mk_cpuinfo pi5 "Raspberry Pi 5 Model B Rev 1.0"
chkeq "Pi 5 → model 5" "$(detect_pi_model "$TMPDIR/cpuinfo-pi5")" "5"
detect_pi_is_zero "$TMPDIR/cpuinfo-pi5"; chkrc "Pi 5 is_zero=false" $? 1

# ===========================================================================
echo
echo "=== Test 2: Pi 4 variants ==="
mk_cpuinfo pi4 "Raspberry Pi 4 Model B Rev 1.4"
chkeq "Pi 4 Model B → model 4" "$(detect_pi_model "$TMPDIR/cpuinfo-pi4")" "4"

mk_cpuinfo pi400 "Raspberry Pi 400 Rev 1.0"
chkeq "Pi 400 → model 4" "$(detect_pi_model "$TMPDIR/cpuinfo-pi400")" "4"

mk_cpuinfo cm4 "Raspberry Pi Compute Module 4 Rev 1.1"
chkeq "CM4 → model 4" "$(detect_pi_model "$TMPDIR/cpuinfo-cm4")" "4"

# ===========================================================================
echo
echo "=== Test 3: Pi 3 variants ==="
mk_cpuinfo pi3b  "Raspberry Pi 3 Model B Rev 1.2"
chkeq "Pi 3 Model B → model 3"  "$(detect_pi_model "$TMPDIR/cpuinfo-pi3b")"  "3"

mk_cpuinfo pi3bp "Raspberry Pi 3 Model B Plus Rev 1.3"
chkeq "Pi 3 Model B+ → model 3" "$(detect_pi_model "$TMPDIR/cpuinfo-pi3bp")" "3"

mk_cpuinfo cm3 "Raspberry Pi Compute Module 3 Plus Rev 1.0"
chkeq "CM3+ → model 3" "$(detect_pi_model "$TMPDIR/cpuinfo-cm3")" "3"

# ===========================================================================
echo
echo "=== Test 4: Pi 2 ==="
mk_cpuinfo pi2 "Raspberry Pi 2 Model B Rev 1.1"
chkeq "Pi 2 → model 2" "$(detect_pi_model "$TMPDIR/cpuinfo-pi2")" "2"
detect_pi_is_zero "$TMPDIR/cpuinfo-pi2"; chkrc "Pi 2 is_zero=false" $? 1

# ===========================================================================
echo
echo "=== Test 5: Pi 1 family ==="
mk_cpuinfo pi1b   "Raspberry Pi Model B Rev 2"
chkeq "Pi 1 Model B → model 1" "$(detect_pi_model "$TMPDIR/cpuinfo-pi1b")" "1"

mk_cpuinfo pi1bp  "Raspberry Pi Model B Plus Rev 1.2"
chkeq "Pi 1 Model B+ → model 1" "$(detect_pi_model "$TMPDIR/cpuinfo-pi1bp")" "1"

mk_cpuinfo pi1ap  "Raspberry Pi Model A Plus Rev 1.1"
chkeq "Pi 1 Model A+ → model 1" "$(detect_pi_model "$TMPDIR/cpuinfo-pi1ap")" "1"

# ===========================================================================
echo
echo "=== Test 6: Pi Zero / Zero W → model 0 (regression — was already working) ==="
mk_cpuinfo zero  "Raspberry Pi Zero Rev 1.3"
chkeq "Pi Zero → model 0" "$(detect_pi_model "$TMPDIR/cpuinfo-zero")" "0"
detect_pi_is_zero "$TMPDIR/cpuinfo-zero"; chkrc "Pi Zero is_zero=true" $? 0

mk_cpuinfo zerow "Raspberry Pi Zero W Rev 1.1"
chkeq "Pi Zero W → model 0" "$(detect_pi_model "$TMPDIR/cpuinfo-zerow")" "0"
detect_pi_is_zero "$TMPDIR/cpuinfo-zerow"; chkrc "Pi Zero W is_zero=true" $? 0

# ===========================================================================
echo
echo "=== Test 7: Pi Zero 2 W → model 3 (regression — was 99 before this fix) ==="
mk_cpuinfo zero2w "Raspberry Pi Zero 2 W Rev 1.0"
chkeq "Pi Zero 2 W → model 3" "$(detect_pi_model "$TMPDIR/cpuinfo-zero2w")" "3"
detect_pi_is_zero "$TMPDIR/cpuinfo-zero2w"; chkrc "Pi Zero 2 W is_zero=true" $? 0

# Specifically — verify the Pi-4/5-only choices file gates DON'T match the
# Zero 2 W. With the old buggy detection it'd be model 99, so the boot-order
# / bootloader-version / power-off-on-halt menus would have shown up.
II_MODEL_NUM=$(detect_pi_model "$TMPDIR/cpuinfo-zero2w")
[[ ${II_MODEL_NUM:-0} -ge 4 ]] && fail "Zero 2 W: -ge 4 wrongly true" \
                               || ok "Zero 2 W: -ge 4 false (boot order hidden)"
[[ ${II_MODEL_NUM:-0} -eq 5 ]] && fail "Zero 2 W: -eq 5 wrongly true" \
                               || ok "Zero 2 W: -eq 5 false (USB current hidden)"

# ===========================================================================
echo
echo "=== Test 8: missing / empty cpuinfo → model 99 ==="
chkeq "no file → 99" "$(detect_pi_model "$TMPDIR/does-not-exist")" "99"
detect_pi_is_zero "$TMPDIR/does-not-exist"; chkrc "no file → is_zero false" $? 1

mk_cpuinfo empty ""  # creates a file with 'Model : ' (empty value)
chkeq "empty Model → 99" "$(detect_pi_model "$TMPDIR/cpuinfo-empty")" "99"

# ===========================================================================
echo
echo "=== Test 9: unknown Model line → 99, not is_zero ==="
mk_cpuinfo alien "Raspberry Pi 99 Custom Rev 0.0"
chkeq "alien Model → 99" "$(detect_pi_model "$TMPDIR/cpuinfo-alien")" "99"
detect_pi_is_zero "$TMPDIR/cpuinfo-alien"; chkrc "alien is_zero=false" $? 1

# ---- Test 10: detect_pi_has_internal_rtc ----
echo
echo "=== Test 10: detect_pi_has_internal_rtc ==="
# Pi 5 model string → present (canonical match).
printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "$TMPDIR/devicetree-pi5"
detect_pi_has_internal_rtc "$TMPDIR/devicetree-pi5" "$TMPDIR/no-such-sysfs"
chkrc "Pi 5 model → internal RTC detected" $? 0

# Pi 4 model string → not present (model doesn't match + sysfs absent).
printf 'Raspberry Pi 4 Model B Rev 1.4\0' > "$TMPDIR/devicetree-pi4"
detect_pi_has_internal_rtc "$TMPDIR/devicetree-pi4" "$TMPDIR/no-such-sysfs"
chkrc "Pi 4 model → no internal RTC" $? 1

# Unreadable model but sysfs path exists → present (forward-compat).
mkdir -p "$TMPDIR/fake-sysfs"
detect_pi_has_internal_rtc "$TMPDIR/no-such-model" "$TMPDIR/fake-sysfs"
chkrc "sysfs path present alone → detected (forward-compat)" $? 0

# Both absent → not present.
detect_pi_has_internal_rtc "$TMPDIR/no-such-model" "$TMPDIR/no-such-sysfs"
chkrc "both absent → no internal RTC" $? 1

# Pi 3 model (negative case mirroring detect_pi_model test patterns).
printf 'Raspberry Pi 3 Model B Plus Rev 1.3\0' > "$TMPDIR/devicetree-pi3bp"
detect_pi_has_internal_rtc "$TMPDIR/devicetree-pi3bp" "$TMPDIR/no-such-sysfs"
chkrc "Pi 3 model → no internal RTC" $? 1

echo
echo "=== Done ==="
