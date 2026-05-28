#!/bin/bash
# Tests for manifest_requires_match (lib/manifest.sh) — hardware-gating
# matcher used by pick_* filters and scheduler pre-flight.
#
# Self-contained: tempdir-isolated, stubs os.status via env vars.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/manifest.sh

ok()      { echo "  OK $1"; }
fail()    { echo "  FAIL $1"; }
chkeq()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc()   { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

TMPD=$(mktemp -d)
trap "rm -rf $TMPD" EXIT

# Helper to write a synthetic feature with a given II_REQUIRES_* line.
_mkfeat() {
  local id="$1" req_field="$2" req_value="$3"
  local path="$TMPD/feature-$id.sh"
  cat > "$path" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="$id"
II_TITLE="$id test"
II_CATEGORY="feature"
II_VERSION="1"
$req_field="$req_value"
# === II_MANIFEST_END ===
EOF
  echo "$path"
}

# ---- Test 1: empty expressions = no requirement (rc=0) ----
echo "=== Test 1: empty II_REQUIRES_* = always passes ==="
F=$(_mkfeat foo "II_REQUIRES_PI_MODEL" "")
II_MODEL_NUM=3 manifest_requires_match "$F"
chkrc "empty pi-model = pass" $? 0

# ---- Test 2: PI_MODEL operators ----
echo "=== Test 2: PI_MODEL operators ==="
F=$(_mkfeat pi5min "II_REQUIRES_PI_MODEL" ">=5")
II_MODEL_NUM=5 manifest_requires_match "$F"
chkrc "PI_MODEL >=5 on Pi 5 = pass" $? 0
II_MODEL_NUM=4 manifest_requires_match "$F"
chkrc "PI_MODEL >=5 on Pi 4 = fail" $? 1
II_MODEL_NUM=6 manifest_requires_match "$F"
chkrc "PI_MODEL >=5 on Pi 6 = pass (forward-compat)" $? 0

F=$(_mkfeat pi4eq "II_REQUIRES_PI_MODEL" "==4")
II_MODEL_NUM=4 manifest_requires_match "$F"
chkrc "PI_MODEL ==4 on Pi 4 = pass" $? 0
II_MODEL_NUM=5 manifest_requires_match "$F"
chkrc "PI_MODEL ==4 on Pi 5 = fail" $? 1

F=$(_mkfeat pi3max "II_REQUIRES_PI_MODEL" "<3")
II_MODEL_NUM=2 manifest_requires_match "$F"
chkrc "PI_MODEL <3 on Pi 2 = pass" $? 0
II_MODEL_NUM=3 manifest_requires_match "$F"
chkrc "PI_MODEL <3 on Pi 3 = fail" $? 1

F=$(_mkfeat pibare "II_REQUIRES_PI_MODEL" "5")
II_MODEL_NUM=5 manifest_requires_match "$F"
chkrc "bare PI_MODEL '5' on Pi 5 = pass (== implied)" $? 0
II_MODEL_NUM=4 manifest_requires_match "$F"
chkrc "bare PI_MODEL '5' on Pi 4 = fail" $? 1

# ---- Test 3: RAM_MB and OS_BITS ----
echo "=== Test 3: RAM_MB + OS_BITS ==="
F=$(_mkfeat ram "II_REQUIRES_RAM_MB" ">=2048")
II_MEMORY=2048 manifest_requires_match "$F"
chkrc "RAM>=2048 on 2GB = pass" $? 0
II_MEMORY=1024 manifest_requires_match "$F"
chkrc "RAM>=2048 on 1GB = fail" $? 1
II_MEMORY=Unknown manifest_requires_match "$F"
chkrc "RAM>=2048 on Unknown = fail (treated as 0)" $? 1

F=$(_mkfeat bits "II_REQUIRES_OS_BITS" "64")
II_OS_BITS=64 manifest_requires_match "$F"
chkrc "OS_BITS=64 on 64-bit = pass" $? 0
II_OS_BITS=32 manifest_requires_match "$F"
chkrc "OS_BITS=64 on 32-bit = fail" $? 1

# ---- Test 4: boolean dimensions (LITE/PIZERO/INTERNAL_RTC) ----
echo "=== Test 4: boolean dimensions ==="
F=$(_mkfeat lite "II_REQUIRES_LITE" "==false")
II_IS_LITE=false manifest_requires_match "$F"
chkrc "LITE==false on GUI = pass" $? 0
II_IS_LITE=true  manifest_requires_match "$F"
chkrc "LITE==false on Lite = fail" $? 1

F=$(_mkfeat pizero "II_REQUIRES_PIZERO" "false")
II_IS_PIZERO=false manifest_requires_match "$F"
chkrc "PIZERO=false bare on non-Zero = pass" $? 0
II_IS_PIZERO=true  manifest_requires_match "$F"
chkrc "PIZERO=false on Pi Zero = fail" $? 1

F=$(_mkfeat irtc "II_REQUIRES_INTERNAL_RTC" "==true")
II_HAS_INTERNAL_RTC=true  manifest_requires_match "$F"
chkrc "INTERNAL_RTC==true on Pi 5 = pass" $? 0
II_HAS_INTERNAL_RTC=false manifest_requires_match "$F"
chkrc "INTERNAL_RTC==true on Pi 3 = fail" $? 1
II_HAS_INTERNAL_RTC=""    manifest_requires_match "$F"
chkrc "INTERNAL_RTC==true on unset = fail" $? 1

# ---- Test 5: multi-dimension AND ----
echo "=== Test 5: multi-dimension AND ==="
# NOTE: use FPATH (not PATH) to hold the temp file path. Clobbering PATH
# breaks every external command (cat/grep/etc) on Windows git-bash and
# any host where the manifest helpers shell out.
FPATH="$TMPD/feature-multi.sh"
cat > "$FPATH" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="multi"
II_TITLE="multi"
II_CATEGORY="feature"
II_VERSION="1"
II_REQUIRES_PI_MODEL=">=4"
II_REQUIRES_RAM_MB=">=2048"
II_REQUIRES_OS_BITS="==64"
# === II_MANIFEST_END ===
EOF
II_MODEL_NUM=5 II_MEMORY=4096 II_OS_BITS=64 manifest_requires_match "$FPATH"
chkrc "all-pass = pass" $? 0
II_MODEL_NUM=5 II_MEMORY=4096 II_OS_BITS=32 manifest_requires_match "$FPATH"
chkrc "one fail (bits) = fail" $? 1
II_MODEL_NUM=3 II_MEMORY=4096 II_OS_BITS=64 manifest_requires_match "$FPATH"
chkrc "one fail (pi) = fail" $? 1
II_MODEL_NUM=5 II_MEMORY=1024 II_OS_BITS=64 manifest_requires_match "$FPATH"
chkrc "one fail (ram) = fail" $? 1

# ---- Test 6: case insensitivity on bool ----
echo "=== Test 6: case insensitivity on booleans ==="
F=$(_mkfeat caseupper "II_REQUIRES_LITE" "==FALSE")
II_IS_LITE=false manifest_requires_match "$F"
chkrc "LITE==FALSE matches false" $? 0
II_IS_LITE=False manifest_requires_match "$F"
chkrc "LITE==FALSE matches False" $? 0

# ---- Test 7: no manifest block = pass ----
echo "=== Test 7: file without manifest block = pass ==="
NOMAN="$TMPD/feature-noman.sh"
cat > "$NOMAN" <<EOF
#!/bin/bash
# (no manifest block)
echo body
EOF
manifest_requires_match "$NOMAN"
chkrc "no manifest = pass" $? 0

# ---- Test 8: missing file = fail ----
echo "=== Test 8: missing file ==="
manifest_requires_match "$TMPD/does-not-exist.sh"
chkrc "missing file = fail" $? 1


# ---- Test 9: II_RADIO_ORDER sort ----
echo "=== Test 9: II_RADIO_ORDER sort ==="
SD=$(mktemp -d)
trap "rm -rf $TMPD $SD" EXIT
for n in 3 1 2; do
  cat > "$SD/feature-r${n}.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="r${n}"
II_TITLE="R${n}"
II_CATEGORY="feature"
II_VERSION="1"
II_RADIO_ORDER="${n}"
# === II_MANIFEST_END ===
EOF
done
# Also an unset-order entry — should sort last.
cat > "$SD/feature-rlast.sh" <<EOF
#!/bin/bash
# === II_MANIFEST_BEGIN ===
II_ID="rlast"
II_TITLE="Rlast"
II_CATEGORY="feature"
II_VERSION="1"
# === II_MANIFEST_END ===
EOF

# Use the menu_pick_one_optional sort logic directly via a helper subshell —
# we re-implement the same sort here to validate the algorithm.
export PATH_FEATURES="$SD" PATH_PACKAGES="$SD"
manifest_registry_reload >/dev/null
_manifest_registry_load >/dev/null

# Build the sorted list using the same algorithm as menu_pick_one_optional.
ids="r3 r1 rlast r2"
declare -a _so=()
for _id in $ids; do
  _path=$(manifest_path_for "$_id" 2>/dev/null)
  _order=""
  [[ -n $_path ]] && _order=$(manifest_get_field "$_path" "II_RADIO_ORDER")
  [[ -z $_order ]] && _order=999
  _so+=("${_order}|${_id}")
done
sorted=$(printf '%s\n' "${_so[@]}" | sort -t'|' -k1n -s | awk -F'|' '{print $2}' | tr '\n' ' ')
sorted=${sorted% }
chkeq "II_RADIO_ORDER sort 'r3 r1 rlast r2' → 'r1 r2 r3 rlast'" "$sorted" "r1 r2 r3 rlast"
echo "=== Done ==="
