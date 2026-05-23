#!/bin/bash
# Tests for lib/database.sh — AUTO resolution, remote-DB rule, applicability.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/log.sh
log_init "test-database" "/tmp/test-database.log"

# Pull in PATH_* so DATABASE_STATE_FILE / CREDS_FILE resolve to the
# tempdir we control below (NOT /etc/installicious).
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
export PATH_STATE="$TMPDIR/state"
export PATH_CONFIG="$TMPDIR/config"
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
echo
echo "=== Done ==="
