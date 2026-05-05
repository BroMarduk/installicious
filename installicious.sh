#!/bin/bash

# The main file to run for Installicious.
MODULE="Installicious Main"
DESCRIPTION="The starting point for Installicious. Run this first and watch the magic happen."
FILE_CONFIG_INSTALLICIOUS="config/installicious.config"
EXIT_REBOOT=255
RESUME_UNIT_SRC="resources/installicious-resume.service"
RESUME_UNIT_DEST="/etc/systemd/system/installicious-resume.service"

# Privilege check. Installicious edits /etc, /boot, /var, manages systemd
# units, runs raspi-config, etc. — all of which require root. Fail fast with
# a clear message rather than letting the user discover the missing
# permissions one obscure error at a time.
#
# The systemd resume service invokes us as root directly (no SUDO_USER); a
# normal first-run should be `sudo bash installicious.sh`, which gives us
# both root privileges AND a SUDO_USER value for downstream installers
# (install-bash etc.) that need to know the original user's home.
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

# Whiptail color theme. The default Debian/Pi OS theme paints active list
# rows as white-on-light-blue, which the user found hard to read.
#
# IMPORTANT: NEWT_COLORS must be a single-line, colon-separated value.
# Multi-line / newline-separated forms are silently ignored on Pi OS's
# whiptail and the default theme is used instead.
#
# This theme uses black-on-white for the bulk of the dialog (the "normal
# box" look) and visible highlights for the two cursor-following states:
#   actlistbox / actcheckbox / actsellistbox / acttextbox = black,cyan
#     (cursor-row highlight in listboxes/checklists/inputboxes)
#   actbutton = white,blue
#     (focused button — distinct from the listbox highlight so the
#     action-target is unambiguous)
#
# Exported so child shells (options.sh, the per-installer whiptail
# invocations like menu_show_required) inherit it.
export NEWT_COLORS="root=lightgray,blue:window=black,white:border=black,white:shadow=black,gray:title=black,white:button=black,white:actbutton=black,cyan:compactbutton=black,white:checkbox=black,white:actcheckbox=black,cyan:entry=black,white:label=black,white:listbox=black,white:actlistbox=black,cyan:sellistbox=black,cyan:actsellistbox=black,cyan:textbox=black,white:acttextbox=black,cyan:helpline=white,blue:roottext=white,blue:emptyscale=,black:fullscale=,white:disentry=gray,white"

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

# Make sure the installers directory variable can be found.
if [[ -z $PATH_INSTALLERS ]]; then
  echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find a value for the installers directory in the configuration $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
  exit 1
else
  # Check for scripts directory as it must exist.
  if [[ ! -d $PATH_INSTALLERS ]]; then
    echo "$(date '+%Y-%m-%d %T.%5N') - FAIL - [$MODULE] Unable to find the scripts installers $PATH_INSTALLERS specifed in the configuration file $FILE_CONFIG_INSTALLICIOUS." | sudo tee --append $FILE_LOG_INSTALLER
    exit 1
  fi
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
# gating in install-rconf.choices.sh works for the Zero family without
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
# functions (e.g. install-rconf.choices.sh) to filter desktop-only options
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

if (whiptail --title "$MODULE" --defaultno --no-button "Cancel" --yes-button "OK" --yesno "Do you want to setup $MODULE? $DESCRIPTION\n\n$II_MODEL with $II_FULL_NAME\n\nInstallicious $INSTALLICIOUS_VERSION" 14 80) then
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious $INSTALLICIOUS_VERSION started by user $CURRENTUSER" | sudo tee --append $FILE_LOG_INSTALLER
  bash "$PATH_SCRIPTS/options.sh"
else
  echo "$(date '+%Y-%m-%d %T.%5N') - INFO - [$MODULE] Installicious canceled by user $CURRENTUSER" | sudo tee --append $FILE_LOG_INSTALLER
fi
