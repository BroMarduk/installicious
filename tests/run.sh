#!/bin/bash
# tests/run.sh — parallel test runner.
#
# Each tests/test-*.sh file is self-contained (its own tempdir, no shared
# state with other tests) so they can run concurrently. Sequentially the
# full suite takes ~8 minutes on Windows Bash; parallel wall clock is
# bounded by the slowest single test (currently test-roundtrip at ~2min).
#
# Usage:
#   tests/run.sh                  # parallel, summary only
#   tests/run.sh --sequential     # one at a time (legacy loop)
#   tests/run.sh --verbose        # parallel, dump every test's output
#
# Exit code: 0 if every test rc=0, non-zero otherwise. Failing tests'
# output is dumped at the end regardless of --verbose.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

mode="parallel"
verbose=0
for arg in "$@"; do
  case "$arg" in
    --sequential) mode="sequential" ;;
    --verbose)    verbose=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

log_dir=$(mktemp -d)
trap "rm -rf $log_dir" EXIT

declare -A test_pid
declare -A test_log
declare -A test_start
declare -a tests
for t in tests/test-*.sh; do
  tests+=("$t")
done

run_one() {
  local t="$1"
  local log="$log_dir/$(basename "$t" .sh).log"
  test_log["$t"]="$log"
  test_start["$t"]=$(date +%s%3N)
  bash "$t" >"$log" 2>&1 &
  test_pid["$t"]=$!
}

if [[ $mode == "parallel" ]]; then
  for t in "${tests[@]}"; do run_one "$t"; done
fi

failed=()
total_start=$(date +%s%3N)
for t in "${tests[@]}"; do
  if [[ $mode == "sequential" ]]; then
    run_one "$t"
  fi
  if wait "${test_pid[$t]}"; then
    rc=0
  else
    rc=$?
  fi
  elapsed=$(( $(date +%s%3N) - ${test_start[$t]} ))
  if [[ $rc -eq 0 ]]; then
    printf "PASS  %6dms  %s\n" "$elapsed" "$(basename "$t")"
  else
    printf "FAIL  %6dms  %s (rc=%d)\n" "$elapsed" "$(basename "$t")" "$rc"
    failed+=("$t")
  fi
  if [[ $verbose -eq 1 ]]; then
    sed 's/^/  | /' "${test_log[$t]}"
  fi
done
total_elapsed=$(( $(date +%s%3N) - total_start ))

echo
printf "Total: %d test(s), %d failed, %dms wall clock (%s).\n" \
  "${#tests[@]}" "${#failed[@]}" "$total_elapsed" "$mode"

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "=== Failure output ==="
  for t in "${failed[@]}"; do
    echo "--- $t ---"
    cat "${test_log[$t]}"
    echo
  done
  exit 1
fi
