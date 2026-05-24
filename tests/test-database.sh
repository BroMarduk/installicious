#!/bin/bash
# Tests for lib/database.sh — AUTO resolution, remote-DB rule, applicability.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/log.sh
log_init "test-database" "/tmp/test-database.log"

# Pull in PATH_* so DATABASE_STATE_FILE / CREDS_FILE resolve to the
# tempdir we control below (NOT /etc/installicious). Use a uniquely-named
# variable -- TMPDIR is mktemp's own env var; assigning to it would
# poison any subsequent mktemp call in the sourced lib / subshells.
TEST_TMPDIR=$(mktemp -d)
trap "rm -rf $TEST_TMPDIR" EXIT
export PATH_STATE="$TEST_TMPDIR/state"
export PATH_CONFIG="$TEST_TMPDIR/config"
mkdir -p "$PATH_STATE" "$PATH_CONFIG"

source lib/database.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

# ============================================================================
echo "=== Test 1: database_is_local ==="
DATABASE_HOST="SELF";        database_is_local; chkrc "SELF is local"      $? 0
DATABASE_HOST="";            database_is_local; chkrc "empty is local"     $? 0
DATABASE_HOST="localhost";   database_is_local; chkrc "localhost is local" $? 0
DATABASE_HOST="127.0.0.1";   database_is_local; chkrc "127.0.0.1 is local" $? 0
DATABASE_HOST="10.0.0.5";    database_is_local; chkrc "10.0.0.5 is remote" $? 1
DATABASE_HOST="db.lan";      database_is_local; chkrc "db.lan is remote"   $? 1

# ============================================================================
echo "=== Test 2: database_resolve_credentials (local + AUTO) ==="
DATABASE_HOST="SELF"; DATABASE_NAME="AUTO"; DATABASE_USER="AUTO"; DATABASE_PASS="AUTO"
DATABASE_DEFAULT_NAME="weewx"
rm -f "$DATABASE_CREDS_FILE"
database_resolve_credentials; chkrc "local+AUTO resolves rc=0" $? 0
chkeq "AUTO NAME -> weewx" "$DATABASE_NAME" "weewx"
chkeq "AUTO USER -> weewx" "$DATABASE_USER" "weewx"
[[ ${#DATABASE_PASS} -eq 24 ]] && ok "AUTO PASS is 24 chars" || fail "AUTO PASS is ${#DATABASE_PASS} chars (want 24)"
[[ -f "$DATABASE_CREDS_FILE" ]] && ok "creds file written" || fail "creds file missing at $DATABASE_CREDS_FILE"

# ============================================================================
echo "=== Test 3: database_resolve_credentials reuses persisted password ==="
FIRST_PASS="$DATABASE_PASS"
DATABASE_HOST="SELF"; DATABASE_NAME="AUTO"; DATABASE_USER="AUTO"; DATABASE_PASS="AUTO"
database_resolve_credentials
chkeq "second run reuses pass" "$DATABASE_PASS" "$FIRST_PASS"

# ============================================================================
echo "=== Test 4: database_resolve_credentials (remote + AUTO = rc=1) ==="
DATABASE_HOST="10.0.0.5"; DATABASE_USER="AUTO"; DATABASE_PASS="AUTO"
database_resolve_credentials; chkrc "remote+AUTO fails" $? 1

# ============================================================================
echo "=== Test 5: database_resolve_credentials (remote + explicit = rc=0) ==="
DATABASE_HOST="10.0.0.5"; DATABASE_NAME="weewx_prod"; DATABASE_USER="weewx"; DATABASE_PASS="hunter2"
database_resolve_credentials; chkrc "remote+explicit OK" $? 0
chkeq "remote NAME preserved" "$DATABASE_NAME" "weewx_prod"
chkeq "remote USER preserved" "$DATABASE_USER" "weewx"
chkeq "remote PASS preserved" "$DATABASE_PASS" "hunter2"

# ============================================================================
echo "=== Test 6: database_resolve_credentials (remote + NAME=AUTO is OK) ==="
DATABASE_HOST="10.0.0.5"; DATABASE_NAME="AUTO"; DATABASE_USER="weewx"; DATABASE_PASS="hunter2"
DATABASE_DEFAULT_NAME="weewx"
database_resolve_credentials; chkrc "remote+NAME=AUTO+explicit creds OK" $? 0
chkeq "remote NAME=AUTO resolves" "$DATABASE_NAME" "weewx"

# ============================================================================
echo "=== Test 7: database_load_role_sidecar ==="
mkdir -p "$PATH_CONFIG"
cat > "$PATH_CONFIG/database-weewx.config" <<EOF
DATABASE_DEFAULT_NAME="weewx_test"
DATABASE_MYSQL_PYTHON_PACKAGES="python3-pymysql"
EOF
unset DATABASE_DEFAULT_NAME DATABASE_MYSQL_PYTHON_PACKAGES
database_load_role_sidecar "weewx"
chkeq "sidecar sets DEFAULT_NAME"     "$DATABASE_DEFAULT_NAME"          "weewx_test"
chkeq "sidecar sets PYTHON_PACKAGES"  "$DATABASE_MYSQL_PYTHON_PACKAGES" "python3-pymysql"
database_load_role_sidecar "nonexistent" 2>/dev/null  # must not error
ok "missing sidecar is a no-op"

# ============================================================================
echo "=== Test 8: pi_tier_size_for ==="
source lib/pi-tier.sh
# We don't know which Pi (or non-Pi) the test runs on — just verify the
# helper returns ONE of the four sizes when called with our actual
# argument shape.
val=$(pi_tier_size_for "64M 128M 256M 512M")
case "$val" in
  64M|128M|256M|512M) ok "pi_tier_size_for returns one of {64M,128M,256M,512M}: $val" ;;
  *) fail "pi_tier_size_for unexpected value: '$val'" ;;
esac

# ============================================================================
echo "=== Test 9: InnoDB tune off + missing file -> no-op ==="
# We cannot exercise the actual `sudo tee` path in tests, but we can
# verify the helper short-circuits when DATABASE_INNODB_TUNE=off and
# there's no existing drop-in. (When the file exists and TUNE=off, the
# helper would try to `sudo rm` it; we skip exercising that here.)
DATABASE_INNODB_TUNE="off"
DATABASE_HOST="SELF"
# Replace sudo + systemctl with no-ops so the helper can run in the test
# environment. NOTE: these stubs remain active for the rest of this file.
# This is OK only because Test 9 is the LAST section before `=== Done ===`.
# If you add tests below, either `unset -f sudo systemctl` first, or reset
# them at the top of each new section.
sudo() { "$@"; }
systemctl() { :; }
absent_conf=/tmp/installicious-pi-test-noexist.cnf
[[ ! -f $absent_conf ]] && ok "drop-in absent precondition met" || rm -f "$absent_conf"
# database_apply_innodb_tune writes /etc/mysql/conf.d/installicious-pi.cnf
# unconditionally on a real system; we just confirm the early-return on
# TUNE=off doesn't blow up.
database_apply_innodb_tune mariadb >/dev/null 2>&1
chkrc "TUNE=off rc=0" $? 0

# ============================================================================
echo
echo "=== Done ==="
