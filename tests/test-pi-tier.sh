#!/bin/bash
# Tests for lib/pi-tier.sh — pi_tier_size_for + pi_cpu_choice.
#
# Both helpers read from /proc directly, which we can't mock cleanly
# without adding env-var indirection to the lib. So the tests are split
# in two layers:
#   1. Smoke checks that always pass: helper returns a value from the
#      caller-supplied set, given the caller-supplied argument shape.
#      Same pattern as test-database.sh's Test 8 for pi_tier_size_for.
#   2. Host-state checks gated on what /proc looks like on the test
#      host (Windows git-bash, Linux CI, Pi). Each gate asserts the
#      detection path it implies. Skipped (not failed) when the host
#      doesn't match.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/pi-tier.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
skip()  { echo "  SKIP $1"; }
chkin() {
  # chkin "label" "<value>" "<allowed1> <allowed2> ..."
  local label="$1" got="$2" allowed="$3"
  local item
  for item in $allowed; do
    if [[ "$got" == "$item" ]]; then ok "$label: $got"; return; fi
  done
  fail "$label (got '$got', want one of: $allowed)"
}

# ============================================================================
echo "=== Test 1: pi_tier_size_for returns a value from the caller's set ==="
val=$(pi_tier_size_for "S M L X")
chkin "pi_tier_size_for 'S M L X'" "$val" "S M L X"

val=$(pi_tier_size_for "64M 128M 256M 512M")
chkin "pi_tier_size_for '64M 128M 256M 512M'" "$val" "64M 128M 256M 512M"

# ============================================================================
echo "=== Test 2: pi_cpu_choice returns a value from the caller's set ==="
val=$(pi_cpu_choice "FAST SLOW")
chkin "pi_cpu_choice 'FAST SLOW'" "$val" "FAST SLOW"

val=$(pi_cpu_choice "zstd lz4")
chkin "pi_cpu_choice 'zstd lz4'" "$val" "zstd lz4"

# ============================================================================
echo "=== Test 3: pi_cpu_choice on hosts without /proc/device-tree/model -> fast ==="
# The "no device-tree" branch is the early-return that always picks fast
# (rationale: non-Pi host, modern CPU). We can pin this deterministically
# on any host where /proc/device-tree/model is absent — covers Windows
# git-bash and most non-Pi Linux.
if [[ ! -r /proc/device-tree/model ]]; then
  val=$(pi_cpu_choice "FAST SLOW")
  [[ "$val" == "FAST" ]] && ok "no device-tree -> fast (got '$val')" \
                          || fail "no device-tree should give FAST (got '$val')"
else
  skip "host has /proc/device-tree/model — can't exercise the non-Pi branch here"
fi

# ============================================================================
echo "=== Test 4: pi_tier_size_for tier matches host RAM when not a known Pi ==="
# When /proc/device-tree/model is absent OR not a Pi 5 / Pi Zero match,
# pi_tier_size_for falls through to MemTotal. We can verify the tier
# matches the host's actual RAM bracket on hosts that miss device-tree
# (Windows git-bash, generic Linux). Skipped on Pi hosts where the
# device-tree path may shortcut the result.
if [[ -r /proc/meminfo ]] && [[ ! -r /proc/device-tree/model ]]; then
  mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
  mem_mb=$(( mem_kb / 1024 ))
  if   (( mem_mb >= 6144 )); then expected=X
  elif (( mem_mb >= 3072 )); then expected=L
  elif (( mem_mb >= 1280 )); then expected=M
  else                            expected=S
  fi
  val=$(pi_tier_size_for "S M L X")
  [[ "$val" == "$expected" ]] && ok "RAM-fallback tier ($mem_mb MB) -> $val" \
                              || fail "RAM-fallback tier ($mem_mb MB): got '$val', want '$expected'"
else
  skip "host has /proc/device-tree/model or no /proc/meminfo — can't exercise the RAM-fallback branch here"
fi

# ============================================================================
echo "=== Test 5: extra positional args are ignored (forward-compat) ==="
# Both helpers use `read -r` which only assigns the first N tokens.
# Callers passing extras shouldn't break the helper.
val=$(pi_tier_size_for "S M L X EXTRA1 EXTRA2")
chkin "pi_tier_size_for ignores extra args" "$val" "S M L X"

val=$(pi_cpu_choice "FAST SLOW UNKNOWN EXTRA")
chkin "pi_cpu_choice ignores extra args" "$val" "FAST SLOW"

echo "=== Done ==="
