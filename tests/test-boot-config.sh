#!/bin/bash
# Tests for lib/boot-config.sh — idempotent /boot/firmware/config.txt
# manager. Self-contained; uses BOOT_CONFIG_PATH_OVERRIDE to redirect at
# a tempdir file. PATH_BACKUP redirected as well.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source lib/boot-config.sh

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPD=$(mktemp -d)
trap "rm -rf $TMPD" EXIT

export BOOT_CONFIG_PATH_OVERRIDE="$TMPD/config.txt"
export PATH_BACKUP="$TMPD/backup"

_reset_state() {
  _BOOT_CONFIG_BACKUP_DONE=0
  rm -f "$BOOT_CONFIG_PATH_OVERRIDE"
  rm -rf "$PATH_BACKUP"
}

# ---- Test 1: cold start dtparam_set ----
echo "=== Test 1: cold start dtparam_set ==="
_reset_state
: > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_dtparam_set i2c_arm on
chkeq "single dtparam line" "$(cat "$BOOT_CONFIG_PATH_OVERRIDE")" $'\ndtparam=i2c_arm=on'

# ---- Test 2: idempotent set ----
echo "=== Test 2: idempotent dtparam_set ==="
_reset_state
: > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_dtparam_set i2c_arm on
before=$(md5sum "$BOOT_CONFIG_PATH_OVERRIDE" | awk '{print $1}')
boot_config_dtparam_set i2c_arm on
after=$(md5sum "$BOOT_CONFIG_PATH_OVERRIDE" | awk '{print $1}')
chkeq "second set is byte-identical" "$after" "$before"

# ---- Test 3: uncomment ----
echo "=== Test 3: uncomment a commented dtparam ==="
_reset_state
cat > "$BOOT_CONFIG_PATH_OVERRIDE" <<EOF
# some prior comment
#dtparam=i2c_arm=on
arm_64bit=1
EOF
boot_config_dtparam_set i2c_arm on
grep -q '^dtparam=i2c_arm=on$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "uncommented line present" $? 0
grep -q '^arm_64bit=1$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "other lines preserved" $? 0
# Should not duplicate the line.
n=$(grep -c '^dtparam=i2c_arm=' "$BOOT_CONFIG_PATH_OVERRIDE")
chkeq "exactly one dtparam=i2c_arm line" "$n" "1"

# ---- Test 4: replace differing value ----
echo "=== Test 4: replace differing value ==="
_reset_state
cat > "$BOOT_CONFIG_PATH_OVERRIDE" <<EOF
dtparam=i2c_arm=off
EOF
boot_config_dtparam_set i2c_arm on
grep -q '^dtparam=i2c_arm=on$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "rewrote off → on" $? 0

# ---- Test 5: overlay_add cold ----
echo "=== Test 5: overlay_add cold ==="
_reset_state
: > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_overlay_add rtc "dtoverlay=i2c-rtc,ds3231"
grep -q '^# === installicious:rtc begin ===$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "begin fence present" $? 0
grep -q '^dtoverlay=i2c-rtc,ds3231$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "content line present" $? 0
grep -q '^# === installicious:rtc end ===$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "end fence present" $? 0

# ---- Test 6: overlay_add idempotent ----
echo "=== Test 6: overlay_add idempotent ==="
boot_config_overlay_add rtc "dtoverlay=i2c-rtc,ds3231"
n=$(grep -c '^# === installicious:rtc begin ===$' "$BOOT_CONFIG_PATH_OVERRIDE")
chkeq "still exactly one begin fence" "$n" "1"

# ---- Test 7: overlay_add content change rewrites in place ----
echo "=== Test 7: overlay_add content change ==="
boot_config_overlay_add rtc "dtoverlay=i2c-rtc,pcf8523"
grep -q '^dtoverlay=i2c-rtc,pcf8523$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "new content present" $? 0
grep -q '^dtoverlay=i2c-rtc,ds3231$' "$BOOT_CONFIG_PATH_OVERRIDE" && \
  fail "old content lingered" || ok "old content removed"
n=$(grep -c '^# === installicious:rtc begin ===$' "$BOOT_CONFIG_PATH_OVERRIDE")
chkeq "fences still single" "$n" "1"

# ---- Test 8: overlay_remove ----
echo "=== Test 8: overlay_remove ==="
boot_config_overlay_remove rtc
grep -q 'installicious:rtc' "$BOOT_CONFIG_PATH_OVERRIDE" && \
  fail "block still present after remove" || ok "block removed"

# ---- Test 9: multiple owners coexist ----
echo "=== Test 9: multiple owners coexist ==="
_reset_state
: > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_overlay_add rtc "dtoverlay=i2c-rtc,ds3231"
boot_config_overlay_add sensor "dtoverlay=imx708"
boot_config_overlay_remove rtc
grep -q 'sensor' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "sensor block survived rtc removal" $? 0
grep -q 'rtc' "$BOOT_CONFIG_PATH_OVERRIDE" && \
  fail "rtc block lingered" || ok "rtc gone"

# ---- Test 10: CRLF tolerance ----
echo "=== Test 10: CRLF tolerance ==="
_reset_state
printf 'dtparam=i2c_arm=off\r\narm_64bit=1\r\n' > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_dtparam_set i2c_arm on
grep -q $'\r' "$BOOT_CONFIG_PATH_OVERRIDE" && \
  fail "output still has CR" || ok "output is LF-only"
grep -q '^dtparam=i2c_arm=on$' "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "value rewritten despite CRLF input" $? 0

# ---- Test 11: legacy /boot/config.txt fallback ----
echo "=== Test 11: legacy /boot/config.txt fallback ==="
unset BOOT_CONFIG_PATH_OVERRIDE
LEGACY="$TMPD/boot-config.txt"
: > "$LEGACY"
# Simulate the firmware path missing by pointing the override at the
# legacy location.
export BOOT_CONFIG_PATH_OVERRIDE="$LEGACY"
boot_config_dtparam_set spi on
grep -q '^dtparam=spi=on$' "$LEGACY"
chkrc "legacy fallback works" $? 0

# ---- Test 12: boot_config_backup_once ----
echo "=== Test 12: backup_once one-shot ==="
_reset_state
export BOOT_CONFIG_PATH_OVERRIDE="$TMPD/config.txt"
echo "test contents" > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_backup_once
n=$(find "$PATH_BACKUP/boot-config" -type d -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
chkeq "one snapshot dir created" "$n" "1"
boot_config_backup_once  # second call → no-op
n=$(find "$PATH_BACKUP/boot-config" -type d -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
chkeq "still one snapshot dir after second call" "$n" "1"

# ---- Test 13: overlay_has ----
echo "=== Test 13: overlay_has ==="
_reset_state
: > "$BOOT_CONFIG_PATH_OVERRIDE"
boot_config_overlay_has rtc; chkrc "fresh file: no rtc block" $? 1
boot_config_overlay_add rtc "dtoverlay=i2c-rtc,ds3231"
boot_config_overlay_has rtc; chkrc "after add: rtc block present" $? 0

# ---- Test 14: fence detection is exact-line, not substring ----
echo "=== Test 14: fence detection is anchored (regression test) ==="
_reset_state
# Pre-seed a comment that contains the fence substring but isn't an actual fence.
cat > "$BOOT_CONFIG_PATH_OVERRIDE" <<EOF
# Documentation note: the fence format is # === installicious:rtc begin === / end ===
arm_64bit=1
EOF
# overlay_has must NOT report 'rtc' as present.
boot_config_overlay_has rtc
chkrc "overlay_has reports absent despite substring match in comment" $? 1
# overlay_add must insert the fence cleanly even with the substring-bearing comment present.
boot_config_overlay_add rtc "dtoverlay=i2c-rtc,ds3231"
n=$(grep -c "^# === installicious:rtc begin ===$" "$BOOT_CONFIG_PATH_OVERRIDE")
chkeq "exactly one real begin-fence line after add" "$n" "1"
# The comment must still be present (unchanged).
grep -q "^# Documentation note:" "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "documentation comment preserved" $? 0

echo "=== Done ==="
