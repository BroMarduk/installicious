#!/bin/bash

# lib/scheduler.sh - Run installer queues in dependency order.
#
# The scheduler reads II_DEPS from each manifest (via lib/manifest.sh) to:
#   - resolve transitive dependencies (auto-add missing deps to the queue)
#   - topologically sort the queue so each installer runs after its deps
#   - execute each installer with `--install`, halting on the reboot signal
#     (exit code 255)
#
# Usage:
#   source lib/manifest.sh
#   source lib/log.sh
#   source lib/scheduler.sh
#   queue=$(scheduler_resolve_deps git weewx)   # adds transitive deps
#   sorted=$(scheduler_topo_sort $queue)        # deps-first ordering
#   scheduler_run_queue $sorted                 # invokes each installer
#
# Or in one call:
#   scheduler_run_resolved git weewx            # resolve + sort + run
#
# Returns 0 on full success, 255 on reboot signal, non-zero on any installer
# failure (continues the queue past failures unless 255 is returned, matching
# the behavior of the legacy scripts/process-options.sh).

EXIT_REBOOT=255

# SCHEDULER_LAST_ERROR is set by helpers below when they fail. The wrapper
# scheduler_run_resolved exposes it to the caller so options.sh can render the
# message in a whiptail dialog.
SCHEDULER_LAST_ERROR=""

# scheduler_resolve_deps <id...> -> echo <id...> + transitive deps, one per line.
# Uses the manifest registry. Returns rc=1 if any resolved ID has no
# installer file (a missing dep is a hard error: pre-flight validation refuses
# to start a queue with an unresolvable dep).
#
# On failure: populates SCHEDULER_LAST_ERROR with a human-readable message
# naming the missing IDs, and emits the same message on stderr. The Pillar-6
# dependency-validation guard. Callers should surface the error to the user
# (via whiptail or similar) rather than proceed.
scheduler_resolve_deps() {
  SCHEDULER_LAST_ERROR=""
  local -A seen=()
  local -a queue=("$@")
  local -a output=()
  local -a missing=()
  local id deps dep path
  while [[ ${#queue[@]} -gt 0 ]]; do
    id="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n ${seen[$id]:-} ]] && continue
    seen[$id]=1
    output+=("$id")
    path=$(manifest_path_for "$id")
    if [[ -z $path ]]; then
      missing+=("$id")
      continue
    fi
    deps=$(manifest_get_field "$path" "II_DEPS")
    for dep in $deps; do
      [[ -n ${seen[$dep]:-} ]] && continue
      queue+=("$dep")
    done
  done
  printf '%s\n' "${output[@]}"
  if [[ ${#missing[@]} -gt 0 ]]; then
    SCHEDULER_LAST_ERROR="Missing installer(s): ${missing[*]}"
    echo "scheduler_resolve_deps: $SCHEDULER_LAST_ERROR" >&2
    return 1
  fi
  return 0
}

# scheduler_topo_sort <id...> -> echo IDs in dependency order (deps before
# dependents), one per line. Returns rc=2 on cycle detection.
# Edges considered are only those between IDs in the input set; deps not in the
# set are ignored (caller should resolve_deps first if needed).
scheduler_topo_sort() {
  local -a input=("$@")
  [[ ${#input[@]} -eq 0 ]] && return 0
  local -A in_set=()
  local -A indeg=()
  local -A deps_of=()
  local id path deps dep
  for id in "${input[@]}"; do
    in_set[$id]=1
    indeg[$id]=0
    deps_of[$id]=""
  done
  for id in "${input[@]}"; do
    path=$(manifest_path_for "$id")
    [[ -z $path ]] && continue
    deps=$(manifest_get_field "$path" "II_DEPS")
    deps_of[$id]="$deps"
    for dep in $deps; do
      [[ -n ${in_set[$dep]:-} ]] || continue
      indeg[$id]=$((indeg[$id] + 1))
    done
  done

  local -a ready=()
  for id in "${input[@]}"; do
    [[ ${indeg[$id]} -eq 0 ]] && ready+=("$id")
  done

  local -a result=()
  local node
  while [[ ${#ready[@]} -gt 0 ]]; do
    node="${ready[0]}"
    ready=("${ready[@]:1}")
    result+=("$node")
    for id in "${input[@]}"; do
      [[ ${indeg[$id]:-0} -eq 0 ]] && continue
      for dep in ${deps_of[$id]}; do
        if [[ $dep == "$node" ]]; then
          indeg[$id]=$((indeg[$id] - 1))
          [[ ${indeg[$id]} -eq 0 ]] && ready+=("$id")
        fi
      done
    done
  done

  if [[ ${#result[@]} -ne ${#input[@]} ]]; then
    echo "scheduler_topo_sort: cycle detected in dependency graph" >&2
    return 2
  fi
  printf '%s\n' "${result[@]}"
}

# scheduler_run_queue <id...>
# Runs each installer with `--install`, halting on exit 255 (reboot signal).
# Other failures are logged via log_warn and the queue continues.
#
# If lib/state.sh is loaded, also persists the queue state across the run so
# scheduler_resume can pick up where we left off after a reboot. If state is
# already present (we're resuming), starts from the recorded cursor.
#
# Caller should have called log_init beforehand.
# Returns: 0 on full success, 255 on reboot, last non-zero rc otherwise.
scheduler_run_queue() {
  local -a ids=("$@")
  local total=${#ids[@]}
  [[ $total -eq 0 ]] && return 0

  local cursor=0
  if declare -F state_load >/dev/null \
     && declare -F state_exists >/dev/null \
     && state_exists; then
    state_load 2>/dev/null
    cursor="${II_QUEUE_CURSOR:-0}"
    [[ $cursor -gt 0 ]] && log_info "Resuming queue from cursor $cursor."
  fi

  if declare -F state_save >/dev/null; then
    state_save "${ids[*]}" "$cursor" "" ""
  fi

  # Record the attempted ID set so post_install_print_queue_summary can
  # render a Succeeded/Failed/Interrupted line per item at end-of-run.
  # Only writes on the FIRST entry (cursor=0); a resume re-enters here
  # with the same id list, so the file is already correct. Safe either
  # way since the file is replaced, not appended, on each call.
  if declare -F post_install_record_attempted >/dev/null; then
    post_install_record_attempted "${ids[@]}"
  fi

  local i id path rc overall_rc=0
  for ((i=cursor; i<total; i++)); do
    id="${ids[i]}"
    path=$(manifest_path_for "$id")
    if [[ -z $path ]]; then
      log_warn "Skipping '$id': no installer registered."
      declare -F state_save_cursor >/dev/null && state_save_cursor "$((i+1))"
      continue
    fi
    declare -F state_save_cursor >/dev/null && state_save_cursor "$i"
    # Phase 0 pre-flight: hardware-requirements check. If the feature's
    # II_REQUIRES_* doesn't match this Pi, skip it and advance the cursor.
    # This is a belt-and-suspenders safety net — the menu filter (see
    # scripts/options.sh::_filter_by_requires) drops these features
    # before they're queued, so this should only fire in odd cases:
    # selections persisted on a different Pi (SD card moved), manual
    # queue.sh edits, or override-file toggles bypassing the menu.
    if declare -F manifest_requires_match >/dev/null \
       && ! manifest_requires_match "$path"; then
      log_warn "Skipping '$id': II_REQUIRES does not match current hardware."
      declare -F state_save_cursor >/dev/null && state_save_cursor "$((i+1))"
      continue
    fi
    log_info "Running installer: $id."
    bash "$path" --install
    rc=$?
    if [[ $rc -eq $EXIT_REBOOT ]]; then
      log_info "Installer $id requested reboot. Halting queue at cursor $i."
      # Tell post_install_apply that a reboot occurred during this queue —
      # commands queued via post_install_run_unless_rebooted will be skipped
      # when the queue eventually completes.
      if declare -F post_install_mark_rebooted >/dev/null; then
        post_install_mark_rebooted
      fi
      return $EXIT_REBOOT
    fi
    if [[ $rc -ne 0 ]]; then
      log_warn "Installer $id exited non-zero ($rc); continuing queue." "$rc"
      overall_rc=$rc
    fi
    declare -F state_save_cursor >/dev/null && state_save_cursor "$((i+1))"
  done

  # Queue complete.
  declare -F state_clear >/dev/null && state_clear
  declare -F resume_service_disable >/dev/null && resume_service_disable
  return $overall_rc
}

# scheduler_run_resolved <id...> - convenience: resolve_deps + topo_sort + run_queue.
# Returns rc=3 if any dep references an installer that doesn't exist; the
# caller can read SCHEDULER_LAST_ERROR to surface the message (e.g. via
# whiptail). Returns rc=2 on dependency-cycle detection.
scheduler_run_resolved() {
  local resolved sorted resolve_rc tmp
  SCHEDULER_LAST_ERROR=""

  # Use a tempfile rather than $(scheduler_resolve_deps ...) so that
  # resolve_deps's global assignment to SCHEDULER_LAST_ERROR survives. A
  # command substitution would run resolve_deps in a subshell and discard
  # that global on exit.
  tmp=$(mktemp) || {
    SCHEDULER_LAST_ERROR="Could not create temp file for dependency resolution."
    log_fail "$SCHEDULER_LAST_ERROR"
    return 1
  }
  scheduler_resolve_deps "$@" > "$tmp"
  resolve_rc=$?
  resolved=$(cat "$tmp")
  rm -f "$tmp"

  if [[ $resolve_rc -ne 0 ]]; then
    log_fail "$SCHEDULER_LAST_ERROR" "$resolve_rc"
    return 3
  fi

  sorted=$(scheduler_topo_sort $resolved)
  local sort_rc=$?
  if [[ $sort_rc -ne 0 ]]; then
    SCHEDULER_LAST_ERROR="Dependency cycle detected; cannot build execution order."
    log_fail "$SCHEDULER_LAST_ERROR" "$sort_rc"
    return $sort_rc
  fi
  # shellcheck disable=SC2086
  scheduler_run_queue $sorted
}

# scheduler_resume - resume an in-flight queue from $PATH_STATE/queue.sh.
# Returns 1 if no state file exists (nothing to resume).
scheduler_resume() {
  if ! declare -F state_load >/dev/null; then
    log_fail "lib/state.sh not loaded; cannot resume."
    return 1
  fi
  if ! state_load 2>/dev/null; then
    log_info "No queue state; nothing to resume."
    return 1
  fi
  if [[ -z ${II_QUEUE_IDS:-} ]]; then
    log_warn "Queue state exists but is empty; clearing."
    declare -F state_clear >/dev/null && state_clear
    return 1
  fi
  log_info "Resuming queue '${II_QUEUE_IDS}' from cursor ${II_QUEUE_CURSOR:-0}."
  # shellcheck disable=SC2086
  scheduler_run_queue $II_QUEUE_IDS
}
