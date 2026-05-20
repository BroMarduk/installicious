#!/bin/bash
# Tests for lib/installer_apt.sh — the apt-only installer driver.
# Stubs out apt_is_installed / apt_ensure_installed / apt_remove so the test
# runs without sudo or real apt activity. Drives installer_apt_main end-to-end
# the same way the scheduler does.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

export LIB_LOG_USE_SUDO=0

source lib/installer_apt.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export PATH_STATUS="$TMPDIR/status"
export PATH_LOGS="$TMPDIR/logs"
export PATH_STATE="$TMPDIR/state"
mkdir -p "$PATH_STATUS" "$PATH_LOGS" "$PATH_STATE"

# ---- Stub apt operations. Behavior is driven by env arrays. -----------------
declare -A FAKE_APT_INSTALLED=()       # pkg -> "1" if installed
declare -a APT_INSTALL_LOG=()          # ordered log of installs
declare -a APT_REMOVE_LOG=()           # ordered log of removes
FAKE_APT_INSTALL_RC=0                  # toggle to simulate failure
FAKE_APT_REMOVE_RC=0

apt_is_installed() {
  local pkg="$1"
  [[ -n ${FAKE_APT_INSTALLED[$pkg]:-} ]]
}
apt_ensure_installed() {
  local pkg="$1"
  APT_INSTALL_LOG+=("$pkg")
  if [[ $FAKE_APT_INSTALL_RC -eq 0 ]]; then
    FAKE_APT_INSTALLED[$pkg]=1
    return 0
  fi
  return $FAKE_APT_INSTALL_RC
}
apt_remove() {
  local pkg="$1"
  APT_REMOVE_LOG+=("$pkg")
  if [[ $FAKE_APT_REMOVE_RC -eq 0 ]]; then
    unset 'FAKE_APT_INSTALLED[$pkg]'
    return 0
  fi
  return $FAKE_APT_REMOVE_RC
}
reset_stubs() {
  FAKE_APT_INSTALLED=()
  APT_INSTALL_LOG=()
  APT_REMOVE_LOG=()
  FAKE_APT_INSTALL_RC=0
  FAKE_APT_REMOVE_RC=0
}

# ===========================================================================
echo "=== Test 1: _installer_apt_pre_var name derivation ==="
chkeq "git"          "$(_installer_apt_pre_var git)"          "GIT_FW_PRE_INSTALLED"
chkeq "python3-pip"  "$(_installer_apt_pre_var python3-pip)"  "PYTHON3_PIP_FW_PRE_INSTALLED"
chkeq "build-essential" "$(_installer_apt_pre_var build-essential)" "BUILD_ESSENTIAL_FW_PRE_INSTALLED"

# ===========================================================================
echo
echo "=== Test 2: install when package not pre-installed ==="
reset_stubs
II_ID="git"; II_TITLE="Git"; II_VERSION="1"; II_APT_PACKAGES="git"
installer_apt_main --install >/dev/null 2>&1
rc=$?
chkrc "install rc=0" $rc 0
chkeq "git installed via stub" "${APT_INSTALL_LOG[*]}" "git"
chkeq "pre-state recorded as false" \
  "$(status_get "$PATH_STATUS/git.status" GIT_FW_PRE_INSTALLED)" "false"
chkeq "framework state = completed" \
  "$(status_get "$PATH_STATUS/git.status" GIT_FW_STATE)" "completed"

# ===========================================================================
echo
echo "=== Test 3: install when package already present ==="
reset_stubs
FAKE_APT_INSTALLED[curl]=1
II_ID="curl"; II_TITLE="curl"; II_VERSION="1"; II_APT_PACKAGES="curl"
installer_apt_main --install >/dev/null 2>&1
rc=$?
chkrc "install rc=0" $rc 0
chkeq "pre-state recorded as true" \
  "$(status_get "$PATH_STATUS/curl.status" CURL_FW_PRE_INSTALLED)" "true"
# apt_ensure_installed is still called (it's idempotent), so the log shows it.
chkeq "ensure called once" "${APT_INSTALL_LOG[*]}" "curl"

# ===========================================================================
echo
echo "=== Test 4: skip when already recorded at version ==="
reset_stubs
# Reuse the curl status from Test 3 — version 1 is already complete.
II_ID="curl"; II_TITLE="curl"; II_VERSION="1"; II_APT_PACKAGES="curl"
installer_apt_main --install >/dev/null 2>&1
rc=$?
chkrc "skip returns 0" $rc 0
chkeq "no apt activity on skip" "${APT_INSTALL_LOG[*]}" ""

# ===========================================================================
echo
echo "=== Test 5: bumped II_VERSION re-runs install ==="
reset_stubs
FAKE_APT_INSTALLED[curl]=1
II_ID="curl"; II_TITLE="curl"; II_VERSION="2"; II_APT_PACKAGES="curl"
installer_apt_main --install >/dev/null 2>&1
rc=$?
chkrc "rerun rc=0" $rc 0
chkeq "ensure called for v2" "${APT_INSTALL_LOG[*]}" "curl"

# ===========================================================================
echo
echo "=== Test 6: install failure marks status failed ==="
reset_stubs
FAKE_APT_INSTALL_RC=100
II_ID="bork"; II_TITLE="bork"; II_VERSION="1"; II_APT_PACKAGES="bork"
installer_apt_main --install >/dev/null 2>&1
rc=$?
chkrc "install rc=100 propagated" $rc 100
chkeq "framework state = failed" \
  "$(status_get "$PATH_STATUS/bork.status" BORK_FW_STATE)" "failed"

# ===========================================================================
echo
echo "=== Test 7: uninstall removes packages we installed ==="
reset_stubs
# Set up: a fresh install where pkg was NOT pre-existing, then uninstall.
II_ID="htop"; II_TITLE="htop"; II_VERSION="1"; II_APT_PACKAGES="htop"
installer_apt_main --install >/dev/null 2>&1
APT_INSTALL_LOG=()
APT_REMOVE_LOG=()
installer_apt_main --uninstall >/dev/null 2>&1
rc=$?
chkrc "uninstall rc=0" $rc 0
chkeq "htop removed" "${APT_REMOVE_LOG[*]}" "htop"
chkeq "framework state = uninstalled" \
  "$(status_get "$PATH_STATUS/htop.status" HTOP_FW_STATE)" "uninstalled"

# ===========================================================================
echo
echo "=== Test 8: uninstall leaves pre-existing packages alone ==="
reset_stubs
FAKE_APT_INSTALLED[wget]=1
II_ID="wget"; II_TITLE="wget"; II_VERSION="1"; II_APT_PACKAGES="wget"
installer_apt_main --install >/dev/null 2>&1
APT_REMOVE_LOG=()
installer_apt_main --uninstall >/dev/null 2>&1
rc=$?
chkrc "uninstall rc=0" $rc 0
chkeq "wget NOT removed (pre-existing)" "${APT_REMOVE_LOG[*]}" ""

# ===========================================================================
echo
echo "=== Test 9: multi-package installer ==="
reset_stubs
FAKE_APT_INSTALLED[bar]=1   # bar already there; foo and baz are new
II_ID="multi"; II_TITLE="Multi"; II_VERSION="1"; II_APT_PACKAGES="foo bar baz"
installer_apt_main --install >/dev/null 2>&1
rc=$?
chkrc "multi-install rc=0" $rc 0
chkeq "all three installed" "${APT_INSTALL_LOG[*]}" "foo bar baz"
chkeq "foo pre-state false" \
  "$(status_get "$PATH_STATUS/multi.status" FOO_FW_PRE_INSTALLED)" "false"
chkeq "bar pre-state true"  \
  "$(status_get "$PATH_STATUS/multi.status" BAR_FW_PRE_INSTALLED)" "true"
chkeq "baz pre-state false" \
  "$(status_get "$PATH_STATUS/multi.status" BAZ_FW_PRE_INSTALLED)" "false"

APT_REMOVE_LOG=()
installer_apt_main --uninstall >/dev/null 2>&1
rc=$?
chkrc "multi-uninstall rc=0" $rc 0
# foo and baz removed; bar left in place (pre-existed).
chkeq "removed only foo + baz" "${APT_REMOVE_LOG[*]}" "foo baz"

# ===========================================================================
echo
echo "=== Test 10: empty II_APT_PACKAGES is a hard error ==="
reset_stubs
II_ID="empty"; II_TITLE="Empty"; II_VERSION="1"; II_APT_PACKAGES=""
installer_apt_main --install >/dev/null 2>&1
chkrc "rc=2 for empty packages" $? 2

# ===========================================================================
echo
echo "=== Test 11: installer_apt_ensure_deps success and failure ==="
reset_stubs
installer_apt_ensure_deps a b c >/dev/null 2>&1
chkrc "all deps installed rc=0" $? 0
chkeq "log records all deps" "${APT_INSTALL_LOG[*]}" "a b c"

reset_stubs
FAKE_APT_INSTALL_RC=42
installer_apt_ensure_deps x y z >/dev/null 2>&1
chkrc "first failure short-circuits" $? 42
chkeq "log records only first attempt" "${APT_INSTALL_LOG[*]}" "x"

# ===========================================================================
echo
echo "=== Test 12: apt upgrade-mode helpers + freshness window ==="
# Both upgrade variants exist (pkupd dispatches on PKUPD_UPGRADE_MODE).
declare -F apt_dist_upgrade_fresh >/dev/null && ok "apt_dist_upgrade_fresh defined" \
  || fail "apt_dist_upgrade_fresh missing"
declare -F apt_upgrade_fresh >/dev/null && ok "apt_upgrade_fresh defined" \
  || fail "apt_upgrade_fresh missing"

# _apt_is_fresh underpins the PKUPD_SKIP_WINDOW_MIN re-run skip: a step is
# "fresh" (skipped) if its recorded success timestamp is within
# ACCEPTABLE_TIME_DELTA_SEC. pkupd sets that var from PKUPD_SKIP_WINDOW_MIN*60.
ACCEPTABLE_TIME_DELTA_SEC=3600   # 60-minute window, pkupd's default

_apt_is_fresh ""; chkrc "empty timestamp -> stale (re-run)" $? 1

recent=$(date -d '-10 minutes' '+%Y-%m-%d %T' 2>/dev/null || date '+%Y-%m-%d %T')
_apt_is_fresh "$recent"; chkrc "10 min ago, 60 min window -> fresh (skip)" $? 0

old=$(date -d '-120 minutes' '+%Y-%m-%d %T' 2>/dev/null)
if [[ -n $old ]]; then
  _apt_is_fresh "$old"; chkrc "120 min ago, 60 min window -> stale (re-run)" $? 1
fi

ACCEPTABLE_TIME_DELTA_SEC=0      # PKUPD_SKIP_WINDOW_MIN=0 disables the skip
_apt_is_fresh "$recent"; chkrc "window 0 -> always stale (re-run)" $? 1

echo
echo "=== Done ==="
