#!/bin/bash

# setup.sh - Bootstrap installicious from wherever it was extracted to its
# permanent home (PATH_INSTALLICIOUS, default /etc/installicious), then run.
#
# Typical first-Pi deployment:
#
#   cd /tmp
#   wget -qO- https://github.com/BroMarduk/installicious/archive/refs/heads/ai-refactor.tar.gz \
#     | tar xz
#   sudo bash installicious-ai-refactor/setup.sh
#
# setup.sh does:
#   1. resolves its own location and sources config/installicious.config to
#      learn the destination ($PATH_INSTALLICIOUS).
#   2. chmod 755 on all the .sh files (so they're executable after extraction).
#   3. if the source location is not the destination, copy everything there.
#   4. create runtime directories (logs, status, state, backup).
#   5. exec installicious.sh from the destination.

# Resolve the script's own directory regardless of how it's invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Source config to learn the destination path.
if [[ ! -f config/installicious.config ]]; then
  echo "FAIL: config/installicious.config not found in $SCRIPT_DIR" >&2
  exit 1
fi
# shellcheck disable=SC1091
source config/installicious.config

DEST="${PATH_INSTALLICIOUS:-/etc/installicious}"

# Make scripts runnable in the source tree.
chmod 755 setup.sh installicious.sh 2>/dev/null
chmod 755 dependencies/*.sh features/*.sh packages/*.sh roles/*.sh scripts/*.sh 2>/dev/null
[[ -d lib ]]   && chmod 755 lib/*.sh 2>/dev/null
[[ -d tests ]] && chmod 755 tests/*.sh 2>/dev/null

# If we're not already living at the destination, sync there.
# rsync --delete removes files that are no longer in the source tree —
# essential for cleaning up renamed/retired feature/package/role files
# (cp -R would leave stale orphans behind, which then show up as
# duplicate IDs in the manifest registry and cause weird half-broken
# behavior). Excludes: runtime dirs that hold per-install state we
# don't want to nuke. The user's menu_edit_config overrides live in
# state/menu-config.sh, kept by the state/ exclusion. backup snapshots
# created during prior --install runs stay too.
#
# *.dan is also excluded: those are the user's personal override files
# (e.g. overrides/weewx.conf.dan) — gitignored, so they're never in the
# downloaded source tree. Without this exclude, `--delete` would wipe
# them on every re-sync. The exclude protects them in BOTH directions:
# rsync neither copies nor deletes them, so they persist untouched at
# $DEST exactly like state/menu-config.sh does.
if [[ "$SCRIPT_DIR" != "$DEST" ]]; then
  echo "[setup] Syncing to $DEST"
  sudo mkdir -p "$DEST"
  if command -v rsync >/dev/null 2>&1; then
    sudo rsync -a --delete \
      --exclude='/state/' \
      --exclude='/status/' \
      --exclude='/logs/' \
      --exclude='/backup/' \
      --exclude='*.dan' \
      "$SCRIPT_DIR"/ "$DEST"/
  else
    # Fallback: cp + manual prune of common framework dirs so renamed
    # files don't linger. Less thorough than rsync but better than nothing.
    echo "[setup] rsync not available; falling back to cp -R (renamed files may linger)"
    for d in features packages roles lib scripts resources dependencies tests; do
      [[ -d "$DEST/$d" ]] && sudo rm -rf "$DEST/$d"
    done
    sudo cp -R "$SCRIPT_DIR"/. "$DEST"/
  fi
fi

# Runtime directories — installicious creates these on the fly too, but having
# them present up front keeps the first-run logs cleaner.
sudo mkdir -p "$DEST/${PATH_LOGS:-logs}"
sudo mkdir -p "$DEST/${PATH_STATUS:-status}"
sudo mkdir -p "$DEST/${PATH_STATE:-state}"
sudo mkdir -p "$DEST/${PATH_BACKUP:-backup}"

# Install the resume systemd unit so request_reboot can enable it. The unit's
# ConditionPathExists check keeps it dormant until queue.sh exists, so just
# leaving the file in place is harmless.
RESUME_UNIT_SRC="$DEST/${PATH_RESOURCES:-resources}/installicious-resume.service"
RESUME_UNIT_DST="/etc/systemd/system/installicious-resume.service"
if [[ -f "$RESUME_UNIT_SRC" ]]; then
  if [[ ! -f "$RESUME_UNIT_DST" ]] || ! cmp -s "$RESUME_UNIT_SRC" "$RESUME_UNIT_DST" 2>/dev/null; then
    sudo install -m 0644 "$RESUME_UNIT_SRC" "$RESUME_UNIT_DST"
    sudo systemctl daemon-reload
    echo "[setup] Installed $RESUME_UNIT_DST"
  fi
fi

# Install the /etc/profile.d/ wrapper that defines the `installicious` shell
# function. Lets the user run `installicious` (which invokes installicious.sh
# under sudo) instead of `sudo bash installicious.sh` and gets auto shell
# reload at the end when a feature requests it (e.g. bash customizer).
WRAPPER_SRC="$DEST/${PATH_RESOURCES:-resources}/installicious-shell.sh"
WRAPPER_DST="/etc/profile.d/installicious.sh"
if [[ -f "$WRAPPER_SRC" ]]; then
  if [[ ! -f "$WRAPPER_DST" ]] || ! cmp -s "$WRAPPER_SRC" "$WRAPPER_DST" 2>/dev/null; then
    sudo install -m 0644 "$WRAPPER_SRC" "$WRAPPER_DST"
    echo "[setup] Installed $WRAPPER_DST — start a new shell, then run 'installicious' instead of 'bash installicious.sh' for auto shell reload."
  fi
fi

# Only auto-launch installicious if we have a real interactive terminal
# attached. Without a TTY (cron job, remote provisioning script piped
# through ssh, CI runner re-syncing on every deploy), the whiptail menu
# would hang invisibly waiting on user input. In that case just print a
# clear next-step pointer and exit cleanly — setup.sh's primary job is
# to install the files, the menu launch is a convenience for the
# interactive bootstrap case.
if [ -t 0 ] && [ -t 1 ]; then
  echo "[setup] Setup complete. Launching $DEST/installicious.sh ..."
  cd "$DEST"
  # We're already root (setup.sh was invoked via sudo). Re-sudo would
  # overwrite $SUDO_USER to "root", which would lose track of the real
  # user that install-bash and friends need to configure dotfiles for.
  bash "$DEST/installicious.sh"
else
  echo "[setup] Setup complete (non-interactive — not auto-launching the menu)."
  echo "[setup] To open the menu, run one of:"
  echo "[setup]   installicious                    (uses the shell wrapper; new shell required)"
  echo "[setup]   sudo bash $DEST/installicious.sh (direct, any shell)"
fi
