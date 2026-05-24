#!/bin/bash

# lib/verify.sh — primitives + generic fallback for `installicious --verify`.
#
# Helpers come in three layers:
#
# 1. Primitives — verify_dpkg_installed, verify_systemd_active,
#    verify_port_listening, verify_file_exists,
#    verify_require_completed_state.
#    Each takes minimal args, returns rc 0/1 (or 0/2 for the
#    status-state check), and prints one stderr diagnostic on failure
#    so a calling do_verify can capture + forward to stdout.
#
# 2. Generic fallback — verify_generic <id>. Drives the primitives off
#    the manifest's II_APT_PACKAGES + the optional II_SERVICE field +
#    the status file's pre-state record. Most do_verify bodies are just
#    `verify_generic "$II_ID"`.
#
# 3. Dispatcher — verify_dispatch_main "$@". The main loop that
#    `installicious --verify` invokes. Extracted as a function so tests
#    can call it directly without forking installicious.sh.
#
# Callers must have already sourced:
#   lib/log.sh lib/status.sh lib/manifest.sh config/installicious.config

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

# verify_dpkg_installed <pkg> -> rc 0 if dpkg-query reports "ok installed".
# Prints "dpkg: <pkg> not installed (status=<status-or-missing>)" to stderr
# on failure for the caller to capture + forward.
verify_dpkg_installed() {
  local pkg="$1" status
  status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)
  if [[ "$status" == *"ok installed"* ]]; then
    return 0
  fi
  echo "dpkg: $pkg not installed (status=${status:-missing})" >&2
  return 1
}

# verify_systemd_active <unit> -> rc 0 if systemctl is-active --quiet $unit.
# Prints "systemctl is-active <unit>: <state>" on failure.
verify_systemd_active() {
  local unit="$1" state
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    return 0
  fi
  state=$(systemctl is-active "$unit" 2>/dev/null || true)
  echo "systemctl is-active $unit: ${state:-unknown}" >&2
  return 1
}

# verify_port_listening <port> [tcp|udp] -> rc 0 if `ss -lnt` (or -lnu for
# udp) shows something LISTEN-ing on $port.
# Prints "port $port/$proto: not listening" on failure.
verify_port_listening() {
  local port="$1" proto="${2:-tcp}"
  local flag
  case "$proto" in
    tcp) flag="-lnt" ;;
    udp) flag="-lnu" ;;
    *)
      echo "verify_port_listening: unknown proto '$proto' (expected tcp|udp)" >&2
      return 1
      ;;
  esac
  # ss output: "LISTEN 0 511 *:80 ..."  -- match :PORT at column boundary.
  if ss $flag 2>/dev/null | awk -v p="$port" '
       NR > 1 {
         n = split($4, a, ":")
         if (a[n] == p) { found = 1; exit }
       }
       END { exit !found }
     '; then
    return 0
  fi
  echo "port $port/$proto: not listening" >&2
  return 1
}

# verify_file_exists <path> -> rc 0 if $path exists.
# Prints "file $path: missing" on failure.
verify_file_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    return 0
  fi
  echo "file $path: missing" >&2
  return 1
}

# verify_require_completed_state <id> -> rc 0 silent if status_state $id
# is "completed"; rc 2 with one stdout reason line otherwise. Every
# do_verify MUST call this (or verify_generic) at the top so the
# dispatcher sees NOT INSTALLED for non-completed items.
verify_require_completed_state() {
  local id="$1" state
  state=$(status_state "$id" 2>/dev/null)
  if [[ "$state" == "completed" ]]; then
    return 0
  fi
  if [[ -z "$state" ]]; then
    echo "no status file"
  else
    echo "state=$state"
  fi
  return 2
}

# ---------------------------------------------------------------------------
# Generic verifier — drives primitives off manifest + status file.
# ---------------------------------------------------------------------------

# verify_generic <id> -> 0 (OK) | 1 (FAIL) | 2 (NOT INSTALLED).
verify_generic() {
  local id="$1" path apt_packages service status_file
  verify_require_completed_state "$id" || return 2

  path=$(manifest_path_for "$id" 2>/dev/null)
  if [[ -z "$path" ]]; then
    echo "installer script not found for id '$id'"
    return 1
  fi
  apt_packages=$(manifest_get_field "$path" "II_APT_PACKAGES" 2>/dev/null)
  service=$(manifest_get_field "$path" "II_SERVICE" 2>/dev/null)
  status_file=$(status_file_for "$id" 2>/dev/null)

  local rc=0 checked=0 err pkg pre_var pre_val

  if [[ -n "$apt_packages" ]]; then
    for pkg in $apt_packages; do
      pre_var="${pkg^^}"
      pre_var="${pre_var//-/_}"
      pre_var="${pre_var//./_}"
      pre_var="${pre_var}_FW_PRE_INSTALLED"
      pre_val=""
      if [[ -f "$status_file" ]]; then
        pre_val=$(
          # shellcheck disable=SC1090
          source "$status_file" 2>/dev/null
          printf '%s' "${!pre_var:-}"
        )
      fi
      [[ "$pre_val" == "true" ]] && continue  # pre-existing, not ours
      checked=$((checked + 1))
      if ! err=$(verify_dpkg_installed "$pkg" 2>&1); then
        echo "$err"
        rc=1
      fi
    done
  fi

  if [[ -n "$service" ]]; then
    checked=$((checked + 1))
    if ! err=$(verify_systemd_active "$service" 2>&1); then
      echo "$err"
      rc=1
    fi
  fi

  if [[ "$checked" -eq 0 ]]; then
    echo "(no liveness checks declared)"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# Dispatcher — invoked by installicious.sh --verify; extracted for tests.
# ---------------------------------------------------------------------------

_VERIFY_C_OK='\e[0;32m'
_VERIFY_C_FAIL='\e[0;31m'
_VERIFY_C_NOT='\e[0;36m'
_VERIFY_C_RESET='\e[0m'

# verify_dispatch_main "$@" -> overall exit 0 (zero FAILs) or 1 (any FAIL).
# Unknown positional IDs -> exit 2 without running anything else.
verify_dispatch_main() {
  local mode="default" verbose=0
  local -a positional=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --all)        mode="all" ;;
      --list)       mode="list" ;;
      -v|--verbose) verbose=1 ;;
      --*)
        echo "verify: unknown option '$arg'" >&2
        return 2
        ;;
      *) positional+=("$arg") ;;
    esac
  done
  if [[ ${#positional[@]} -gt 0 ]]; then
    mode="ids"
  fi

  if [[ "$mode" == "list" ]]; then
    _verify_print_list
    return 0
  fi

  local -a target_ids=()
  case "$mode" in
    all) mapfile -t target_ids < <(manifest_list_ids) ;;
    ids)
      local id path
      for id in "${positional[@]}"; do
        path=$(manifest_path_for "$id" 2>/dev/null)
        if [[ -z "$path" ]]; then
          echo "verify: unknown id '$id'" >&2
          return 2
        fi
      done
      target_ids=("${positional[@]}")
      ;;
    default)
      local f base
      for f in "$PATH_STATUS"/*.status; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .status)
        [[ "$base" == "os" ]] && continue
        target_ids+=("$base")
      done
      ;;
  esac

  local ok=0 fail=0 not=0 id rc out path title
  for id in "${target_ids[@]}"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    title=$(manifest_get_field "$path" "II_TITLE" 2>/dev/null)
    [[ -z "$title" ]] && title="$id"
    if [[ -z "$path" ]] || [[ ! -f "$path" ]]; then
      _verify_print_row FAIL "$id" "$title" "installer script not found at ${path:-<unresolved>}"
      fail=$((fail + 1))
      continue
    fi
    out=$(bash "$path" --verify 2>&1); rc=$?
    case "$rc" in
      0)
        _verify_print_row OK "$id" "$title"
        [[ $verbose -eq 1 && -n "$out" ]] && _verify_print_indented "$out"
        ok=$((ok + 1))
        ;;
      1)
        _verify_print_row FAIL "$id" "$title"
        [[ -n "$out" ]] && _verify_print_indented "$out"
        fail=$((fail + 1))
        ;;
      2)
        _verify_print_row NOT "$id" "$title"
        [[ -n "$out" ]] && _verify_print_indented "$out"
        not=$((not + 1))
        ;;
      *)
        _verify_print_row FAIL "$id" "$title" "verifier returned unexpected exit code $rc"
        [[ -n "$out" ]] && _verify_print_indented "$out"
        fail=$((fail + 1))
        ;;
    esac
  done

  _verify_print_summary "$ok" "$fail" "$not"
  [[ $fail -gt 0 ]] && return 1
  return 0
}

_verify_print_list() {
  local id title path
  local -a all_ids
  mapfile -t all_ids < <(manifest_list_ids)
  for id in "${all_ids[@]}"; do
    path=$(manifest_path_for "$id" 2>/dev/null)
    title=$(manifest_get_field "$path" "II_TITLE" 2>/dev/null)
    [[ -z "$title" ]] && title="$id"
    printf '         %-22s — %s\n' "$id" "$title"
  done
}

_verify_print_row() {
  local badge="$1" id="$2" title="$3" reason="${4:-}" color label
  case "$badge" in
    OK)   color="$_VERIFY_C_OK";   label="  OK  " ;;
    FAIL) color="$_VERIFY_C_FAIL"; label=" FAIL " ;;
    NOT)  color="$_VERIFY_C_NOT";  label=" NOT  " ;;
  esac
  printf "[${color}%s${_VERIFY_C_RESET}] %-22s — %s\n" "$label" "$id" "$title"
  [[ -n "$reason" ]] && _verify_print_indented "$reason"
}

_verify_print_indented() {
  local block="$1" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '           %s\n' "$line"
  done <<< "$block"
}

_verify_print_summary() {
  local ok="$1" fail="$2" not="$3"
  echo "============================================================"
  echo "  Verify summary"
  echo "============================================================"
  printf '  OK:           %3d\n' "$ok"
  printf '  FAIL:         %3d\n' "$fail"
  printf '  NOT INSTALLED:%3d\n' "$not"
  echo "============================================================"
}
