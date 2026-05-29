#!/bin/bash

# The main file to run for Installicious.
MODULE="Installicious Main"
DESCRIPTION="The starting point for Installicious. Run this first and watch the magic happen."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
EXIT_REBOOT=255
RESUME_UNIT_SRC="resources/installicious-resume.service"
RESUME_UNIT_DEST="/etc/systemd/system/installicious-resume.service"

# Resolve the script's own directory and cd there. The script uses
# relative paths for config / lib / features / packages (e.g.
# `source config/installicious.config`, `bash features/...`), so it
# must run with cwd == its install dir. Without this cd the script
# is brittle:
#   - The /etc/profile.d/installicious wrapper invokes
#     `sudo bash /etc/installicious/installicious.sh "$@"` from the
#     user's cwd (typically $HOME), which makes `config/installicious.
#     config` a relative-to-$HOME path that doesn't exist.
#   - The systemd resume unit invokes us from / (or whichever
#     WorkingDirectory it inherits), same problem.
#   - Tests / one-off invocations from anywhere except /etc/installicious
#     would also hit this.
# Mirrors the same `cd "$SCRIPT_DIR"` setup.sh already does.
INSTALLICIOUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INSTALLICIOUS_DIR" || {
  echo "FAIL: cannot cd into installicious directory '$INSTALLICIOUS_DIR'." >&2
  exit 1
}

# Privilege check. Installicious edits /etc, /boot, /var, manages systemd
# units, runs raspi-config, etc. — all of which require root. Fail fast with
# a clear message rather than letting the user discover the missing
# permissions one obscure error at a time.
#
# The systemd resume service invokes us as root directly (no SUDO_USER); a
# normal first-run should be `sudo bash installicious.sh`, which gives us
# both root privileges AND a SUDO_USER value for downstream installers
# (install-bash etc.) that need to know the original user's home.
# Bypass the root-priv gate for read-only --verify (existing dispatcher
# is in lib/verify.sh and most checks are read-only; do_verify bodies
# that need root sudo -n themselves).
if [[ "${1:-}" != "--verify" ]]; then
  if [[ $EUID -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Installicious must run as root."
    echo
    echo "  Re-run with sudo:"
    echo "      sudo bash $0 $*"
    echo
    echo "  Reason: installicious manages /etc/* config files, /boot/firmware,"
    echo "  systemd units, and apt — all of which require root privileges."
    exit 1
  fi
fi

# ---- Force C.UTF-8 locale for the installicious run ----
#
# Whatever LANG / LC_ALL / LANGUAGE the calling shell pushed at us
# (SSH client, Imager defaults, /etc/default/locale leftovers) gets
# replaced with C.UTF-8 so every subprocess we spawn has a clean env.
# This is the same trick lib/apt.sh and feature-locale.sh's _RC_ENV
# use for their child processes, just generalized to the whole run.
#
# Why force, not just strip-if-broken: locale tooling (perl, python)
# emits "Setting locale failed / Cannot set LC_*" warnings on every
# subprocess invocation when the inherited locale isn't generated on
# the Pi (e.g. LANG=en_GB.UTF-8 inherited from the SSH client when
# the Pi's only generated locale is en_US.UTF-8). Forcing a known-good
# locale makes the warnings unconditionally go away regardless of how
# many locales the Pi has installed.
#
# Why C.UTF-8 (not plain C): plain C treats bytes above 0x7F as raw,
# so whiptail renders any UTF-8 multi-byte character in a feature title
# as "<80><94>" etc. instead of the actual glyph. Em-dashes in the RTC
# chip-titles get mangled this way. C.UTF-8 has the same "no
# translations, no surprises" semantics as C but with UTF-8 byte
# handling. It's provided by libc6 directly on Bookworm / Trixie — no
# locale-gen required — so the warning-suppression property is
# preserved.
#
# The user's interactive shell post-install isn't affected — we only
# rewrite OUR process env. Final system-locale state is owned by
# feature-locale via /etc/default/locale, which the next login picks
# up cleanly.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset LANGUAGE

# Load the installicious version string from the repo-root VERSION file.
# Bumped on every commit (last digit is a per-check-in counter — see the
# "version bump" memory note). Falls back to "unknown" if the file is
# missing (shouldn't happen in a clean checkout but keeps the splash from
# crashing on a partial extract).
INSTALLICIOUS_VERSION=""
if [[ -r "$(dirname "$0")/VERSION" ]]; then
  read -r INSTALLICIOUS_VERSION < "$(dirname "$0")/VERSION"
fi
INSTALLICIOUS_VERSION="${INSTALLICIOUS_VERSION:-unknown}"

# Whiptail color theme: minimal single-key override.
#
# The system default Pi OS / raspi-config theme has the right visual
# behavior for almost everything we care about — focused buttons get
# clearly highlighted, listbox cursor row gets the white-on-blue
# treatment, etc. The only slot we intentionally re-color is `checkbox`
# (the inactive `[ ]` / `[*]` indicator) to cyan-on-lightgray, which
# the user verified gives the look they want without breaking
# button-focus highlighting (a previous attempt at a full custom theme
# silently broke focused-button rendering in some way I couldn't pin
# down — defaults work, ours didn't, so we leave well enough alone for
# every other slot).
export NEWT_COLORS='checkbox=cyan,lightgray'

# Look for installicious.config file in the same directory.
if [[ ! -f $FILE_CONFIG_INSTALLICIOUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the configuration file $FILE_CONFIG_INSTALLICIOUS."
  exit 1
fi

# Input Base Variables and check if it was successful.
source $FILE_CONFIG_INSTALLICIOUS
RET_VAL=$?
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to load variables from the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
  exit 1
fi

# Source helper libs. (Must come after config so PATH_* are set, before any
# state/manifest/apt operations.) Falls back gracefully to the legacy paths if
# the libs are missing.
source lib/log.sh    2>/dev/null || true
source lib/status.sh 2>/dev/null || true
source lib/state.sh  2>/dev/null || true
source lib/apt.sh    2>/dev/null || true
source lib/manifest.sh 2>/dev/null || true

# Non-interactive CLI mode: `installicious --uninstall <id> [<id>...]`.
# Skips the menu / scheduler entirely and dispatches each <id> straight
# to its installer's --uninstall path. Equivalent to the manual
# `cd /etc/installicious && sudo bash features/feature-X.sh --uninstall`
# dance, just without the cd-and-resolve-path-per-id hassle.
# Returns 0 if all uninstalls succeeded, non-zero otherwise.
if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") --uninstall <id> [<id>...]" >&2
    echo "  <id> matches an II_ID from features/ or packages/." >&2
    echo "  Multiple ids are uninstalled in the order given." >&2
    exit 2
  fi
  if ! declare -F manifest_path_for >/dev/null; then
    echo "FAIL: lib/manifest.sh did not load; cannot resolve installer paths." >&2
    exit 1
  fi

  declare -i overall_rc=0
  declare -a _ok=() _fail=() _missing=()
  for _id in "$@"; do
    _path=$(manifest_path_for "$_id" 2>/dev/null)
    if [[ -z $_path || ! -f $_path ]]; then
      echo -e "[ \e[0;31mFAIL\e[0m ] '$_id' — no installer found under features/ or packages/."
      _missing+=("$_id")
      overall_rc=1
      continue
    fi
    echo
    echo "============================================================"
    echo "  Uninstalling $_id  ($(basename "$_path"))"
    echo "============================================================"
    bash "$_path" --uninstall
    _rc=$?
    if [[ $_rc -ne 0 ]]; then
      echo "  (exit $_rc)"
      _fail+=("$_id")
      overall_rc=$_rc
    else
      _ok+=("$_id")
    fi
  done

  echo
  echo "============================================================"
  echo "  Uninstall Summary"
  echo "============================================================"
  [[ ${#_ok[@]}      -gt 0 ]] && printf "  \e[0;32mUninstalled\e[0m: %s\n" "${_ok[*]}"
  [[ ${#_fail[@]}    -gt 0 ]] && printf "  \e[0;31mFailed\e[0m: %s\n"      "${_fail[*]}"
  [[ ${#_missing[@]} -gt 0 ]] && printf "  \e[0;33mNot found\e[0m: %s\n"   "${_missing[*]}"
  echo "============================================================"
  echo
  exit $overall_rc
fi

# --- --verify dispatcher ----------------------------------------------------
# Bypasses the menu, the resume hand-off, and the whiptail dep check
# (verify must work even on a half-broken box). Sources the lean set of
# libs needed: log, status, manifest, verify. The dispatcher itself
# lives in lib/verify.sh (extracted for tests).
if [[ "${1:-}" == "--verify" ]]; then
  shift
  source config/installicious.config || exit 1
  source lib/log.sh
  source lib/status.sh
  source lib/manifest.sh
  source lib/verify.sh
  log_init "installicious --verify" "$PATH_LOGS/installicious.log"
  verify_dispatch_main "$@"
  exit $?
fi

# Make sure the logging directory variable can be found.
if [[ -z $PATH_LOGS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the logging directory in the configuration $FILE_CONFIG_INSTALLICIOUS."
  exit 1
else
  # Check for logs directory as it must exist
  if [[ ! -d $PATH_LOGS ]]; then
    mkdir -p "$PATH_LOGS";
    RET_VAL=$?
    if [[ $RET_VAL -ne 0 ]]; then
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to create the logs directory $PATH_LOGS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS. Error Code: $RET_VAL."
      exit 1
    fi
  fi
fi

# Set log file name and path for the script.
if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi

# Resume after a reboot: if the scheduler queue was persisted by request_reboot,
# hand off to scripts/resume.sh and skip the menus. (Replaces the legacy
# /etc/rc.local --reboot --reboot-type --next-file arg-parsing flow, which
# Pillar 3 retired in favor of a systemd-managed resume.)
if declare -F state_exists >/dev/null && state_exists; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Detected pending queue state; resuming via scripts/resume.sh." | sudo tee --append $FILE_LOG_INSTALLER
  exec bash "$PATH_SCRIPTS/resume.sh"
fi

# Create the log file for this run of Installicious by outputting new file which will overwrite last.
if [[ -e $FILE_LOG_INSTALLER ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installer log created." | sudo tee "$FILE_LOG_INSTALLER"
fi

# Make sure the scripts directory variable can be found.
if [[ -z $PATH_SCRIPTS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the scripts directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for scripts directory as it must exist.
  if [[ ! -d $PATH_SCRIPTS ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the scripts directory $PATH_SCRIPTS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Make sure the features and packages directory variables can be found.
if [[ -z $PATH_FEATURES ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the features directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
elif [[ ! -d $PATH_FEATURES ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the features directory $PATH_FEATURES specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi
if [[ -z $PATH_PACKAGES ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the packages directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
elif [[ ! -d $PATH_PACKAGES ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the packages directory $PATH_PACKAGES specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# PATH_DEPENDENCIES is legacy — the lib/apt.sh helpers replaced the
# dependencies/*-up.sh shim scripts, so the directory is no longer required.
# Left in installicious.config for any unmigrated installer that still
# references it; if absent, that's fine.

# Make sure the config directory variable can be found.
if [[ -z $PATH_CONFIG ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the config directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for config directory as it must exist.
  if [[ ! -d $PATH_CONFIG ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the config directory $PATH_CONFIG specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

# Make sure the status directory variable can be found.
if [[ -z $PATH_STATUS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the status directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi
# Status files now encode persistent install state (FW_STATE / FW_VERSION /
# FW_CONFIG_HASH) — they're how status_should_skip decides whether to re-run.
# Don't wipe them on every run; let each installer's own skip logic decide.
if [[ ! -d $PATH_STATUS ]]; then
  mkdir -p "$PATH_STATUS"
  RET_VAL=$?
  if [[ $RET_VAL -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to create the status directory $PATH_STATUS. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
fi

FILE_STATUS_OS="$PATH_STATUS/os.status"

# Current User
CURRENTUSER="$(whoami)"

# Ensure whiptail is installed (uses lib/apt.sh so the cache is reused across
# installers; replaces the legacy dependencies/whiptail-up.sh shim).
if declare -F apt_ensure_installed >/dev/null; then
  apt_ensure_installed whiptail
  RET_VAL=$?
else
  sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes whiptail
  RET_VAL=$?
fi
if [[ $RET_VAL -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to check for or install package Whiptail. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

# Install the systemd resume unit if it isn't there yet (one-time setup;
# no-op on subsequent runs). request_reboot enables the unit only when a
# reboot is queued, so it stays inert until needed.
if [[ -f $RESUME_UNIT_SRC && ! -f $RESUME_UNIT_DEST ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installing systemd resume unit at $RESUME_UNIT_DEST." | sudo tee --append $FILE_LOG_INSTALLER
  sudo cp "$RESUME_UNIT_SRC" "$RESUME_UNIT_DEST" \
    && sudo systemctl daemon-reload \
    || echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Failed to install resume unit; reboot/resume will not auto-fire." | sudo tee --append $FILE_LOG_INSTALLER
fi

# Reads the Model of the Raspberry Pi
read PIMODEL < /proc/device-tree/model

# Check for Full vs Lite
if [[ -f "/usr/bin/startx" ]]; then
  OSLEVEL="GUI"
  OSLEVELNAME=""
else
  OSLEVEL="Lite"
  OSLEVELNAME=" Lite "
fi

# Reads the Debian Full Version
read DEBIANVERSION < /etc/debian_version

# Reads the OS Release Information
. /etc/os-release

# Makes the Version Codename start with an upper for asthetics
CODENAME=${VERSION_CODENAME^}

if [[ -z $CODENAME ]]; then
  read DEBIAN_VERSION < /etc/debian_version
  NUM_VERSION=${DEBIAN_VERSION%%.*}
  case $NUM_VERSION in
    15)        CODENAME="Duke"     ;;  # future major (forward-compat allowance)
    14)        CODENAME="Forky"    ;;  # next major (forward-compat allowance)
    13)        CODENAME="Trixie"   ;;
    12)        CODENAME="Bookworm" ;;
    *)
      echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unsupported Debian version $NUM_VERSION (installicious supports Bookworm/Trixie and forward-compat with Forky/Duke)." | sudo tee --append $FILE_LOG_INSTALLER
      exit 1
      ;;
  esac
fi

# Reject pre-Bookworm even if VERSION_CODENAME was set in /etc/os-release.
case "${CODENAME,,}" in
  bookworm|trixie|forky|duke) ;;
  *)
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unsupported OS codename '${CODENAME}' (installicious supports Bookworm/Trixie and forward-compat with Forky/Duke)." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
    ;;
esac

# Get OS 32/64 bit version
BITS=$(getconf LONG_BIT)

# Reads the Pi Revision without the bits for OTP and overclocking. Only the bottom 24 bits matter.
PRE_REVISION=$(cat /proc/cpuinfo | grep 'Revision' | awk ' {print $3}' | sed -E 's/.*(.{6})/\1/' | sed 's/^0*//')

# Pad a 0 to the front of the revision if it is less than 4 characters long.
if [[ ! -z $PRE_REVISION ]]; then
  REVISION=$(printf "%04x" "0x$PRE_REVISION")
else
  echo "$(date '+%Y-%m-%d %T.%5N') - WARN - [$MODULE] Unable to detect revision of hardware. Error Code: $RET_VAL." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
fi

## Sets the total memory based on the revision
case $REVISION in
  #  Beta   Raspberry Pi Beta
  #  0002   Raspberry Pi 1 B 1.0
  #  0003   Raspberry Pi 1 B 1.0 (Fuses Mod)
  #  0004   Raspberry Pi 1 B 2.0 (Sony)
  #  0005   Raspberry Pi 1 B 2.0 (Qisda)
  #  0006   Raspberry Pi 1 B 2.0 (Egoman)
  #  0007   Raspberry Pi 1 A 2.0 (Egoman)
  #  0008   Raspberry Pi 1 A 2.0 (Sony)
  #  0009   Raspberry Pi 1 A 2.0 (Qisda)
  #  0012   Raspberry Pi 1 A+ 1.1 (Sony)
  #  0015   Raspberry Pi 1 A+ 1.1 (Embest) - could have 512 but going with low here.
  "Beta" | "0002" | "0003" | "0004" | "0005" | "0006" | "0007" | "0008" | "0009" | "0012" | "0015")
    MEMORY="256";;
  #  000d   Raspberry Pi 1 B 2.0 (Egoman)
  #  000e   Raspberry Pi 1 B 2.0 (Sony)
  #  000f   Raspberry Pi 1 B 2.0 (Qisda)
  #  0010   Raspberry Pi 1 B+ 1.0 (Sony)
  #  0011   Raspberry Pi Compute Module 1 1.0 (Sony)
  #  0013   Raspberry Pi 1 B+ 1.2 (Embest)
  #  0014   Raspberry Pi Compute Module 1 1.0 (Embest)
  #  900021 Raspberry Pi 1 A+ 1.1 (Sony)
  #  900032 Raspberry Pi 1 B+ 1.2 (Sony)
  #  900092 Raspberry Pi Zero 1.2 (Sony)
  #  900093 Raspberry Pi Zero 1.3 (Sony)
  #  920093 Raspberry Pi Zero 1.3 (Embest)
  #  9000c1 Raspberry Pi Zero W 1.1 (Sony)
  #  9020e0 Raspberry Pi 3 A+ 1.0 (Sony)
  #  902120 Raspberry Pi Zero 2 W 1.0 (Sony)
  "000d" | "000e" | "000f" | "0010" | "0011" | "0013" | "0014" | "900021" | "900032" | "900092" | "900093" | "920093" | "9000c1" | "9020e0" | "902120")
    MEMORY="512";;
  #  a01040 Raspberry Pi 2 B 1.0 (Sony)
  #  a01041 Raspberry Pi 2 B 1.1 (Sony)
  #  a21041 Raspberry Pi 2 B 1.1 (Embest)
  #  a22042 Raspberry Pi 2 B 1.2 (Embest)
  #  a02082 Raspberry Pi 3 B 1.2 (Sony)
  #  a020a0 Raspberry Pi Compute Module 3 1.0 (Sony) - also Compute Module 3 Lite
  #  a22082 Raspberry Pi 3 B 1.2 (Embest)
  #  a32082 Raspberry Pi 3 B 1.2 (Sony Japan)
  #  a020d3 Raspberry Pi 3 B+ 1.3 (Sony)
  #  a02100 Raspberry Pi Compute Module 3+ 1.0 (Sony)
  #  a03111 Raspberry Pi 4 B 1.1 (Sony)
  #  a03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  "a01040" | "a01041" | "a21041" | "a22042" | "a02082" | "a020a0" | "a22082" | "a32082" | "a020d3" | "a02100" | "a03111" | "a03140")
    MEMORY="1024";;
  #  b03111 Raspberry Pi 4 B 1.1 (Sony)
  #  b03112 Raspberry Pi 4 B 1.2 (Sony)
  #  b03114 Raspberry Pi 4 B 1.4 (Sony)
  #  b03115 Raspberry Pi 4 B 1.5 (Sony)
  #  b03130 Raspberry Pi 400 1.0 (Sony)
  #  b03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  "b03111" | "b03112" | "b03114" | "b03115" | "b03140")
    MEMORY="2048";;
  #  c03111 Raspberry Pi 4 B 1.1 (Sony)
  #  c03112 Raspberry Pi 4 B 1.2 (Sony)
  #  c03114 Raspberry Pi 4 B 1.4 (Sony)
  #  c03115 Raspberry Pi 4 B 1.5 (Sony)
  #  c03130 Raspberry Pi 400 1.0 (Sony)
  #  c03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  #  c04170 Raspberry Pi 5 B 1.0 (Sony)
  "c03111" | "c03112" | "c03114" | "c03115" | "c03130" | "c03140" | "c04170")
    MEMORY="4096";;
  #  d03114 Raspberry Pi 4 B 1.4 (Sony)
  #  d03115 Raspberry Pi 4 B 1.5 (Sony)
  #  d03140 Raspberry Pi Compute Module 4 1.0 (Sony)
  #  d04170 Raspberry Pi 5 B 1.0 (Sony)
  "d03114" | "d03115" | "d03140" | "d04170")
    MEMORY="8192";;
  *)
    MEMORY="Unknown";;
esac

# Pi-model + Pi-Zero detection via the canonical `Model:` line in
# /proc/cpuinfo (matches upstream raspi-config). lib/detect.sh maps
# Pi Zero / Zero W to model 0 and Pi Zero 2 W to model 3 so the per-Pi
# gating in feature-rconf.choices.sh works for the Zero family without
# special-casing.
source lib/detect.sh
PIMODELNUM=$(detect_pi_model)
if detect_pi_is_zero; then
  IS_PIZERO="true"
else
  IS_PIZERO="false"
fi

# Detect Lite vs Full Pi OS. The desktop edition installs the
# raspberrypi-ui-mods meta-package; Lite does not. Used by installer choices
# functions (e.g. feature-rconf.choices.sh) to filter desktop-only options
# off the menu on Lite systems and skip applying them at install time.
if dpkg-query -W -f='${Status}' raspberrypi-ui-mods 2>/dev/null | grep -q "ok installed"; then
  IS_LITE="false"
else
  IS_LITE="true"
fi

# Writes out the version information to the os.conf file.
echo "II_MODEL=\"${PIMODEL}\"" > $FILE_STATUS_OS
echo "II_MODEL_NUM=\"${PIMODELNUM}\"" >> $FILE_STATUS_OS
echo "II_DEBIAN_VERSION=\"${DEBIANVERSION}\"" >> $FILE_STATUS_OS
echo "II_CODENAME=\"${CODENAME}\"" >> $FILE_STATUS_OS
echo "II_VERSION_NAME=\"${NAME}\"" >> $FILE_STATUS_OS
echo "II_OS_LEVEL=\"${OSLEVEL}\"" >> $FILE_STATUS_OS
echo "II_OS_BITS=\"${BITS}\"" >> $FILE_STATUS_OS
echo "II_IS_LITE=\"${IS_LITE}\"" >> $FILE_STATUS_OS
echo "II_IS_PIZERO=\"${IS_PIZERO}\"" >> $FILE_STATUS_OS
# Pre-compute Pi 5 internal-RTC presence so the II_REQUIRES_INTERNAL_RTC
# manifest matcher (see lib/manifest.sh::manifest_requires_match) doesn't
# re-shell out per candidate-feature during menu render. The detector
# helper in lib/detect.sh stays the canonical source for non-menu code.
if detect_pi_has_internal_rtc; then
  II_HAS_INTERNAL_RTC="true"
else
  II_HAS_INTERNAL_RTC="false"
fi
echo "II_HAS_INTERNAL_RTC=\"${II_HAS_INTERNAL_RTC}\"" >> $FILE_STATUS_OS
echo "II_REVISION=\"${REVISION}\"" >> $FILE_STATUS_OS
echo "II_MEMORY=\"${MEMORY}\"" >> $FILE_STATUS_OS
echo "II_FULL_NAME=\"${NAME} ${DEBIANVERSION}${OSLEVELNAME} (${CODENAME})\"" >> $FILE_STATUS_OS
echo "II_INSTALLICIOUS_PATH=\"${0}\"" >> $FILE_STATUS_OS
# Persist the "real" user — the one who actually invoked installicious — so
# downstream installers (install-bash, etc.) and the post-reboot resume have
# a reliable source. SUDO_USER is the user who sudo'd; falls back to
# CURRENTUSER (whoami) when there's no sudo context (e.g. systemd resume,
# but in that case it'd be "root", which the installer will recognize as
# unconfigured).
II_INSTALLICIOUS_USER="${SUDO_USER:-$CURRENTUSER}"
echo "II_INSTALLICIOUS_USER=\"${II_INSTALLICIOUS_USER}\"" >> $FILE_STATUS_OS

# Load Required Variables
source $FILE_STATUS_OS

# Override-directory hint for the main screen.
#
# Detect whether the user has staged any `*.override` files under
# $PATH_OVERRIDES. These are the drop-the-file artifacts that pre-seed
# config on a fresh Pi (e.g. overrides/weewx.sdb.override,
# overrides/rclone.conf.override, overrides/configuration.override).
# A clean checkout has none — only `configuration.override.example`
# (which the glob deliberately excludes because it ends in `.example`).
# On a fresh-imaged Pi the user often forgets to copy overrides over;
# surfacing the absence here saves a "why isn't my AccuWeather key
# applied?" round-trip later.
#
# Only fires the note when count==0. Path is resolved to an absolute
# location (relative paths in PATH_OVERRIDES expand against the
# installicious install dir) so the hint tells the user EXACTLY where
# to drop files.
shopt -s nullglob
_override_files=("$PATH_OVERRIDES"/*.override)
shopt -u nullglob
_override_note=""
_main_dialog_height=14
if [[ ${#_override_files[@]} -eq 0 ]]; then
  if [[ "$PATH_OVERRIDES" = /* ]]; then
    _override_dir_abs="$PATH_OVERRIDES"
  else
    _override_dir_abs="$INSTALLICIOUS_DIR/$PATH_OVERRIDES"
  fi
  _override_note="NOTE: There are currently no overrides in the $_override_dir_abs directory.  You can continue without them but remember to check configuration settings when that menu appears.\n\n"
  _main_dialog_height=20
fi

if (whiptail --title "$MODULE" --defaultno --no-button "Cancel" --yes-button "OK" --yesno "Do you want to setup $MODULE? $DESCRIPTION\n\n${_override_note}$II_MODEL with $II_FULL_NAME\n\nInstallicious $INSTALLICIOUS_VERSION" "$_main_dialog_height" 80) then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious $INSTALLICIOUS_VERSION started by user $CURRENTUSER" | sudo tee --append $FILE_LOG_INSTALLER
  bash "$PATH_SCRIPTS/options.sh"
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious canceled by user $CURRENTUSER" | sudo tee --append $FILE_LOG_INSTALLER
fi
