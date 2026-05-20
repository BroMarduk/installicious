#!/bin/bash

# lib/apt.sh - APT helpers for installicious.
#
# Provides timestamp-cached apt operations + idempotent install/remove.
# Absorbs the logic from functions/pkupd-software-check.sh and the apt cache
# logic in features/feature-pkupd.sh.
#
# Usage:
#   source lib/installicious.config + lib/log.sh + lib/status.sh + lib/apt.sh
#   apt_ensure_fresh                     # apt-get update if cache stale
#   apt_dist_upgrade_fresh               # apt-get dist-upgrade if cache stale
#   apt_autoremove_fresh                 # apt-get autoremove if cache stale
#   apt_ensure_installed git python3-pip # idempotent installs
#   apt_remove some-package              # purge + autoremove unused deps
#
# Configuration consumed (must be in scope, typically via installicious.config):
#   PATH_STATUS                - directory for status files
#   ACCEPTABLE_TIME_DELTA_SEC  - apt-cache lifetime in seconds. Default 0.
#
# Persistence: $PATH_STATUS/pkupd.status.time records the most recent run of
# each cached operation:
#   PKUPD_UPDATE_RUN
#   PKUPD_UPGRADE_RUN
#   PKUPD_AUTOREMOVE_RUN
#
# Requires lib/status.sh to be sourced first (uses status_get / status_set).

APT_TIME_FILE="${APT_TIME_FILE:-}"

# Env vars forced on every apt-get invocation:
#   LC_ALL=C LANG=C   silences perl / locale tooling (apt-listchanges,
#                     dpkg postinst hooks) that would otherwise inherit
#                     the user's shell LANG and emit "Cannot set
#                     LC_CTYPE" warnings when that locale isn't
#                     generated yet — typical on a fresh RPi Imager
#                     install where LANG=en_GB.UTF-8 but only the C
#                     locale exists. Cosmetic but loud, masks real
#                     errors in the install transcript.
#   DEBIAN_FRONTEND=noninteractive  prevents dpkg/debconf from pausing
#                     for prompts during unattended installs.
#
# Used internally; package-log2ram and other callers that need the same
# wrap can borrow via `${_APT_ENV[@]}` after sourcing this lib.
_APT_ENV=(env LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive)

# apt-get options spliced into every invocation (right after `apt-get`):
#   DPkg::Lock::Timeout=300  Wait up to 5 minutes for the dpkg / apt lock
#                     instead of failing the instant it's contended.
#                     Debian's apt-daily.service / apt-daily-upgrade.service
#                     systemd timers — and unattended-upgrades — grab the
#                     lock on their own schedule (and shortly after boot).
#                     Without the wait, an installicious queue installer
#                     that races one of them dies immediately with
#                     "E: Could not get lock /var/lib/dpkg/lock-frontend".
#                     With it, apt blocks until the background run finishes
#                     and releases the lock, then proceeds.
# Override _APT_LOCK_TIMEOUT before sourcing this lib to change the wait.
_APT_LOCK_TIMEOUT="${_APT_LOCK_TIMEOUT:-300}"
_APT_OPTS=(-o "DPkg::Lock::Timeout=${_APT_LOCK_TIMEOUT}")

_apt_time_file() {
  if [[ -n $APT_TIME_FILE ]]; then
    echo "$APT_TIME_FILE"
  else
    echo "${PATH_STATUS:-status}/pkupd.status.time"
  fi
}

# _apt_is_fresh <last_run_value> - return 0 if within ACCEPTABLE_TIME_DELTA_SEC.
_apt_is_fresh() {
  local last_run="$1"
  local delta="${ACCEPTABLE_TIME_DELTA_SEC:-0}"
  if [[ -z $last_run ]]; then
    return 1
  fi
  local now_unix last_unix age
  now_unix=$(date +%s)
  last_unix=$(date --date="$last_run" +%s 2>/dev/null) || return 1
  age=$((now_unix - last_unix))
  if (( age <= delta )); then
    return 0
  fi
  return 1
}

# _apt_run_with_cache <timestamp_key> <cmd> [args...]
# Runs cmd if the timestamp recorded under <timestamp_key> is older than
# ACCEPTABLE_TIME_DELTA_SEC (or absent). On success records a fresh timestamp.
# Returns 0 on success or skip, non-zero on cmd failure.
_apt_run_with_cache() {
  local key="$1"
  shift
  local time_file
  time_file=$(_apt_time_file)

  local last_run
  last_run=$(status_get "$time_file" "$key")
  if _apt_is_fresh "$last_run"; then
    return 0
  fi

  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  status_set "$time_file" "$key" "$(date '+%Y-%m-%d %T')"
}

# apt_ensure_fresh - run apt-get update if the cached run is stale.
apt_ensure_fresh() {
  _apt_run_with_cache "PKUPD_UPDATE_RUN" \
    sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" update --yes
}

# apt_dist_upgrade_fresh - run apt-get dist-upgrade if the cached run is stale.
# dist-upgrade installs new packages and removes obsolete ones as needed —
# so it WILL pull a new-ABI kernel (which arrives as a brand-new
# linux-image-X.Y.Z package).
apt_dist_upgrade_fresh() {
  _apt_run_with_cache "PKUPD_UPGRADE_RUN" \
    sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" dist-upgrade --yes
}

# apt_upgrade_fresh - run apt-get upgrade if the cached run is stale.
# Plain `upgrade` upgrades installed packages in place but never installs
# NEW packages or removes any — so a new-ABI kernel stays held back until
# the user runs a deliberate dist-upgrade. Shares the PKUPD_UPGRADE_RUN
# cache key with apt_dist_upgrade_fresh so switching modes between runs
# doesn't double-upgrade within the freshness window.
apt_upgrade_fresh() {
  _apt_run_with_cache "PKUPD_UPGRADE_RUN" \
    sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" upgrade --yes
}

# apt_autoremove_fresh - run apt-get autoremove (with --purge) if the cached run is stale.
apt_autoremove_fresh() {
  _apt_run_with_cache "PKUPD_AUTOREMOVE_RUN" \
    sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" --yes --purge autoremove
}

# apt_is_installed <package> - return 0 if dpkg reports the package installed.
apt_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# apt_ensure_installed <package> [<package> ...]
# Install any not-yet-installed packages. Refreshes the apt cache first only if
# at least one package is missing.
apt_ensure_installed() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    if ! apt_is_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  apt_ensure_fresh || return $?
  sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" install --yes "${missing[@]}"
}

# apt_remove <package> [<package> ...] - purge packages and autoremove unused deps.
apt_remove() {
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" --yes --purge autoremove "$@"
}

# apt_add_repo <name> <key-url> <repo-line-or-url> [<keyring-path>]
#
# Sets up a third-party apt repository — needed for packages that aren't in
# the Debian / Raspberry Pi OS archive (weewx and caddy are the two today;
# RPi OS in particular doesn't mirror them).
#
#   <name>              identifier for the sources file
#                       (/etc/apt/sources.list.d/<name>.list)
#   <key-url>           URL to fetch the repo's GPG signing key from; it's
#                       dearmored into <keyring-path>
#   <repo-line-or-url>  EITHER a literal "deb ..." line written verbatim,
#                       OR an http(s):// URL whose body IS the sources-file
#                       content (some vendors — Caddy via Cloudsmith —
#                       publish a generated .list; weewx publishes a static
#                       one-liner)
#   <keyring-path>      where to dearmor the key to. Default
#                       /etc/apt/trusted.gpg.d/<name>.gpg. Pass an explicit
#                       path when the fetched repo line references a
#                       specific signed-by= location (Caddy's does).
#
# Bootstraps wget + gnupg + ca-certificates (the fetch/dearmor/TLS deps),
# refreshes the apt cache afterward so the new repo's packages are visible.
# Idempotent: if the keyring already exists and the sources file content
# already matches, it's a no-op (no re-fetch, no redundant apt-get update).
# Returns non-zero on any step failure.
apt_add_repo() {
  local name="$1" key_url="$2" repo_spec="$3"
  local keyring="${4:-/etc/apt/trusted.gpg.d/${name}.gpg}"
  local list_file="/etc/apt/sources.list.d/${name}.list"

  if [[ -z $name || -z $key_url || -z $repo_spec ]]; then
    echo "apt_add_repo: usage: apt_add_repo <name> <key-url> <repo-line-or-url> [<keyring-path>]" >&2
    return 2
  fi

  # Bootstrap deps — these ARE in the stock archive, so no chicken-and-egg.
  apt_ensure_installed wget gnupg ca-certificates || return $?

  # Resolve the intended sources-file content: a literal deb line, or the
  # body of a URL the vendor publishes.
  local list_content
  if [[ $repo_spec == http://* || $repo_spec == https://* ]]; then
    list_content=$(wget -qO - "$repo_spec") || {
      echo "apt_add_repo: failed to fetch sources content from $repo_spec" >&2
      return 1
    }
  else
    list_content="$repo_spec"
  fi
  if [[ -z $list_content ]]; then
    echo "apt_add_repo: empty sources content for $name" >&2
    return 1
  fi

  # Idempotency: keyring present + sources content already matches → no-op.
  if [[ -f $keyring && -f $list_file ]] \
     && [[ "$(cat "$list_file" 2>/dev/null)" == "$list_content" ]]; then
    return 0
  fi

  # Fetch + dearmor the signing key.
  if ! wget -qO - "$key_url" | sudo gpg --dearmor --yes --output "$keyring" 2>/dev/null; then
    echo "apt_add_repo: failed to fetch/dearmor key for $name from $key_url" >&2
    return 1
  fi
  sudo chmod 0644 "$keyring"

  # Write the sources file.
  printf '%s\n' "$list_content" | sudo tee "$list_file" >/dev/null || return 1

  # Force a refresh so the new repo's packages become installable now.
  sudo "${_APT_ENV[@]}" apt-get "${_APT_OPTS[@]}" update --yes || return $?
  return 0
}

# apt_remove_repo <name> [<keyring-path>]
# Symmetric teardown for apt_add_repo: removes the sources file and the
# dearmored keyring. Default keyring path matches apt_add_repo's default.
apt_remove_repo() {
  local name="$1"
  local keyring="${2:-/etc/apt/trusted.gpg.d/${name}.gpg}"
  [[ -z $name ]] && { echo "apt_remove_repo: usage: apt_remove_repo <name> [<keyring-path>]" >&2; return 2; }
  sudo rm -f "$keyring" "/etc/apt/sources.list.d/${name}.list"
  return 0
}
