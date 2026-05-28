#!/bin/bash
# Tests for lib/rtc.sh — state machine + chip→overlay mapping. Stubs
# /sys/class/rtc, hwclock, timedatectl, apt-get, dpkg via PATH-injected
# scripts. config.txt writes go through BOOT_CONFIG_PATH_OVERRIDE.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPD=$(mktemp -d)
trap "rm -rf $TMPD" EXIT
mkdir -p "$TMPD/bin"

# Stubs that record their calls in $TMPD/calls.log.
cat > "$TMPD/bin/hwclock" <<EOF
#!/bin/bash
echo "hwclock \$*" >> "$TMPD/calls.log"
exit 0
EOF
cat > "$TMPD/bin/timedatectl" <<EOF
#!/bin/bash
echo "timedatectl \$*" >> "$TMPD/calls.log"
# Default: NOT synced. Tests that need 'synced' override by writing
# "yes" into \$TMPD/ntp-synced.
if [[ -f "$TMPD/ntp-synced" ]]; then
  echo "NTPSynchronized=yes"
else
  echo "NTPSynchronized=no"
fi
exit 0
EOF
cat > "$TMPD/bin/dpkg-query" <<EOF
#!/bin/bash
echo "dpkg-query \$*" >> "$TMPD/calls.log"
# Default: fake-hwclock IS installed. Tests that need it absent write
# "absent" into \$TMPD/fake-hwclock-state.
if [[ -f "$TMPD/fake-hwclock-state" ]] && grep -q absent "$TMPD/fake-hwclock-state"; then
  echo "deinstall ok config-files"
else
  echo "install ok installed"
fi
exit 0
EOF
cat > "$TMPD/bin/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> "$TMPD/calls.log"
exit 0
EOF
cat > "$TMPD/bin/sudo" <<EOF
#!/bin/bash
# Pass-through stub — just run the command without sudo. Records the
# call for tests that want to verify sudo was invoked.
echo "sudo \$*" >> "$TMPD/calls.log"
exec "\$@"
EOF
cat > "$TMPD/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$TMPD/calls.log"
exit 0
EOF
chmod +x "$TMPD/bin/"*

# log helpers should not blow up if log.sh isn't sourced (lib/rtc.sh
# sources it conditionally).
log_init() { :; }
log_info() { echo "INFO $*" >> "$TMPD/calls.log"; }
log_warn() { echo "WARN $*" >> "$TMPD/calls.log"; }
log_fail() { echo "FAIL $*" >> "$TMPD/calls.log"; }
log_ok()   { echo "OK $*" >> "$TMPD/calls.log"; }
request_reboot() { echo "request_reboot $*" >> "$TMPD/calls.log"; }
EXIT_REBOOT=255
PATH_BACKUP="$TMPD/backup"
PATH_STATE="$TMPD/state"
mkdir -p "$PATH_STATE"
BOOT_CONFIG_PATH_OVERRIDE="$TMPD/config.txt"
: > "$BOOT_CONFIG_PATH_OVERRIDE"

export PATH="$TMPD/bin:$PATH"

# Source the library AFTER setting overrides.
source lib/boot-config.sh
source lib/rtc.sh

# Re-stub helpers that lib/rtc.sh's sourcing of lib/log.sh /
# lib/reboot.sh would otherwise overwrite. Real log_* and
# request_reboot would either no-op silently or fail noisily because
# state.sh isn't loaded; the test stubs record-and-return-0 so the
# assertions below can grep calls.log.
log_init() { :; }
log_info() { echo "INFO $*" >> "$TMPD/calls.log"; }
log_warn() { echo "WARN $*" >> "$TMPD/calls.log"; }
log_fail() { echo "FAIL $*" >> "$TMPD/calls.log"; }
log_ok()   { echo "OK $*" >> "$TMPD/calls.log"; }
request_reboot() { echo "request_reboot $*" >> "$TMPD/calls.log"; }

_reset() {
  : > "$TMPD/calls.log"
  : > "$BOOT_CONFIG_PATH_OVERRIDE"
  rm -f "$TMPD/state/rtc.state" "$TMPD/ntp-synced" "$TMPD/fake-hwclock-state"
  rm -rf "$TMPD/sys"
  _BOOT_CONFIG_BACKUP_DONE=0
}

# ---- Test 1: chip → overlay mapping (each curated I²C chip) ----
echo "=== Test 1: chip → overlay mapping for I²C chips ==="
for chip in ds3231 pcf8523 ds1307 pcf8563 pcf2127 pcf85063 mcp7940x rv3028 rv3032 abx80x rv1805 m41t62; do
  _reset
  rtc_install "$chip" "i2c" >/dev/null 2>&1
  grep -q "^dtoverlay=i2c-rtc,${chip}$" "$BOOT_CONFIG_PATH_OVERRIDE"
  chkrc "$chip overlay line written" $? 0
done

# ---- Test 2: chip → overlay mapping (each SPI chip) ----
echo "=== Test 2: chip → overlay mapping for SPI chips ==="
for chip in pcf2123 max6902 ds3232; do
  _reset
  rtc_install "$chip" "spi" >/dev/null 2>&1
  grep -q "^dtoverlay=spi-rtc,${chip}$" "$BOOT_CONFIG_PATH_OVERRIDE"
  chkrc "$chip overlay line written (spi)" $? 0
done

# ---- Test 3: Pi-5 built-in path writes NO overlay ----
echo "=== Test 3: pi5-builtin writes no overlay ==="
_reset
rtc_install pcf85063a pi5-builtin >/dev/null 2>&1
grep -q "dtoverlay=" "$BOOT_CONFIG_PATH_OVERRIDE" \
  && fail "overlay line unexpectedly present" \
  || ok "no overlay line for pi5-builtin"

# ---- Test 4: First install → state=staged, reboot requested ----
echo "=== Test 4: first install state=staged ==="
_reset
rtc_install ds3231 i2c >/dev/null 2>&1
rc=$?
chkrc "first install returns EXIT_REBOOT" $rc 255
source "$TMPD/state/rtc.state"
chkeq "state.RTC_CHIP" "$RTC_CHIP" "ds3231"
chkeq "state.RTC_BUS_TYPE" "$RTC_BUS_TYPE" "i2c"
chkeq "state.RTC_PHASE" "$RTC_PHASE" "staged"
grep -q "request_reboot" "$TMPD/calls.log"
chkrc "request_reboot was called" $? 0

# ---- Test 5: Post-reboot resume + NTP synced → state=verified ----
echo "=== Test 5: post-reboot resume + NTP synced → verified ==="
_reset
# Stage first.
rtc_install ds3231 i2c >/dev/null 2>&1
# Simulate post-reboot env: sysfs present.
mkdir -p "$TMPD/sys/class/rtc/rtc0"
echo "rtc-ds3231" > "$TMPD/sys/class/rtc/rtc0/name"
# Override the sysfs path the function reads. lib/rtc.sh uses a hard
# path; we override by symlinking from a tempdir into /sys via a
# wrapper — simpler: just temporarily redirect via a function shim.
# Easiest: stub by overriding the test using an explicit env-var hook.
# Since lib/rtc.sh reads /sys/class/rtc/rtc0 directly, we set
# RTC_SKIP_HWCLOCK=true to bypass hardware probe + hwclock call —
# the state-advancement logic still fires.
touch "$TMPD/ntp-synced"
RTC_SKIP_HWCLOCK=true rtc_install ds3231 i2c >/dev/null 2>&1
rc=$?
chkrc "post-reboot install returns 0" $rc 0
source "$TMPD/state/rtc.state"
chkeq "state advanced to verified" "$RTC_PHASE" "verified"

# ---- Test 6: Post-reboot + NTP NOT synced → state stays 'staged' ----
echo "=== Test 6: post-reboot NTP not synced ==="
_reset
rtc_install ds3231 i2c >/dev/null 2>&1
# No ntp-synced file → timedatectl stub returns NTPSynchronized=no.
# Override the timedatectl stub to a fast-failing one (avoid 60s wait).
cat > "$TMPD/bin/timedatectl" <<'EOF'
#!/bin/bash
echo "NTPSynchronized=no"
exit 0
EOF
# Speed up the wait loop by stubbing sleep to no-op.
cat > "$TMPD/bin/sleep" <<'EOF'
#!/bin/bash
# no-op
exit 0
EOF
chmod +x "$TMPD/bin/timedatectl" "$TMPD/bin/sleep"
RTC_SKIP_HWCLOCK=true rtc_install ds3231 i2c >/dev/null 2>&1
source "$TMPD/state/rtc.state"
chkeq "state stays staged" "$RTC_PHASE" "staged"

# ---- Test 7: Re-run on verified state → no writes, no reboot ----
echo "=== Test 7: re-run on verified ==="
_reset
# Pre-seed verified state.
cat > "$TMPD/state/rtc.state" <<EOF
RTC_CHIP="ds3231"
RTC_BUS_TYPE="i2c"
RTC_OVERLAY_NAME="ds3231"
RTC_PHASE="verified"
EOF
calls_before=$(wc -l < "$TMPD/calls.log")
rtc_install ds3231 i2c >/dev/null 2>&1
rc=$?
chkrc "verified re-run returns 0" $rc 0
grep -q request_reboot "$TMPD/calls.log" \
  && fail "request_reboot called on verified re-run" \
  || ok "no reboot requested on verified re-run"

# ---- Test 8: RTC_PURGE_FAKE_HWCLOCK=no skips purge ----
echo "=== Test 8: RTC_PURGE_FAKE_HWCLOCK=no ==="
_reset
RTC_PURGE_FAKE_HWCLOCK=no rtc_install ds3231 i2c >/dev/null 2>&1
grep -q "apt-get .* purge fake-hwclock" "$TMPD/calls.log" \
  && fail "purge called despite RTC_PURGE_FAKE_HWCLOCK=no" \
  || ok "purge skipped"

# ---- Test 9: Uninstall full reverse ----
echo "=== Test 9: uninstall full reverse ==="
_reset
# Stage + verify first.
rtc_install ds3231 i2c >/dev/null 2>&1
touch "$TMPD/ntp-synced"
RTC_SKIP_HWCLOCK=true rtc_install ds3231 i2c >/dev/null 2>&1
# Pre-condition: state file + overlay block + RTC_PURGED_FAKE_HWCLOCK=yes.
source "$TMPD/state/rtc.state"
chkeq "pre-uninstall: purged=yes" "$RTC_PURGED_FAKE_HWCLOCK" "yes"
grep -q "installicious:rtc begin" "$BOOT_CONFIG_PATH_OVERRIDE"
chkrc "pre-uninstall: overlay block present" $? 0
RTC_SKIP_HWCLOCK=true rtc_uninstall ds3231 i2c >/dev/null 2>&1
grep -q "installicious:rtc" "$BOOT_CONFIG_PATH_OVERRIDE" \
  && fail "overlay block lingered after uninstall" \
  || ok "overlay block removed"
[[ -f $TMPD/state/rtc.state ]] && fail "state file lingered" || ok "state file removed"
grep -q "apt-get .* install fake-hwclock" "$TMPD/calls.log"
chkrc "fake-hwclock reinstalled" $? 0

# ---- Test 10: Uninstall partial (RTC_PURGED_FAKE_HWCLOCK=no) ----
echo "=== Test 10: uninstall partial reverse ==="
_reset
rtc_install ds3231 i2c >/dev/null 2>&1
# Hand-edit state file to mark purged=no.
sed -i 's/RTC_PURGED_FAKE_HWCLOCK="yes"/RTC_PURGED_FAKE_HWCLOCK="no"/' "$TMPD/state/rtc.state"
RTC_SKIP_HWCLOCK=true rtc_uninstall ds3231 i2c >/dev/null 2>&1
grep -q "apt-get .* install fake-hwclock" "$TMPD/calls.log" \
  && fail "fake-hwclock reinstalled despite purged=no" \
  || ok "no fake-hwclock reinstall"

# ---- Test 11: Idempotent rerun (config.txt byte-identical) ----
echo "=== Test 11: idempotent rerun ==="
_reset
rtc_install ds3231 i2c >/dev/null 2>&1
hash1=$(md5sum "$BOOT_CONFIG_PATH_OVERRIDE" | awk '{print $1}')
state1=$(md5sum "$TMPD/state/rtc.state" | awk '{print $1}')
rtc_install ds3231 i2c >/dev/null 2>&1
hash2=$(md5sum "$BOOT_CONFIG_PATH_OVERRIDE" | awk '{print $1}')
state2=$(md5sum "$TMPD/state/rtc.state" | awk '{print $1}')
chkeq "config.txt unchanged" "$hash2" "$hash1"
chkeq "state file unchanged" "$state2" "$state1"

# ---- Test 12: Full chip coverage / table consistency ----
echo "=== Test 12: full chip table coverage ==="
# Iterate every chip-child in the spec table and assert RTC_BUS in the
# resulting state file matches.
declare -A expected_bus=(
  [ds3231]=i2c [pcf8523]=i2c [ds1307]=i2c [pcf8563]=i2c [pcf2127]=i2c
  [pcf85063]=i2c [mcp7940x]=i2c [rv3028]=i2c [rv3032]=i2c [abx80x]=i2c
  [rv1805]=i2c [m41t62]=i2c
  [pcf2123]=spi [max6902]=spi [ds3232]=spi
  [pcf85063a]=pi5-builtin
)
for chip in "${!expected_bus[@]}"; do
  _reset
  rtc_install "$chip" "${expected_bus[$chip]}" >/dev/null 2>&1
  source "$TMPD/state/rtc.state"
  chkeq "$chip bus" "$RTC_BUS_TYPE" "${expected_bus[$chip]}"
done

echo "=== Done ==="
