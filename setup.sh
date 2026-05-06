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

# If we're not already living at the destination, copy there.
if [[ "$SCRIPT_DIR" != "$DEST" ]]; then
  echo "[setup] Installing to $DEST"
  sudo mkdir -p "$DEST"
  # Copy the contents (not the source dir itself) into DEST.
  sudo cp -R "$SCRIPT_DIR"/. "$DEST"/
fi

# Runtime directories — installicious creates these on the fly too, but having
# them present up front keeps the first-run logs cleaner.
sudo mkdir -p "$DEST/${PATH_LOGS:-logs}"
sudo mkdir -p "$DEST/${PATH_STATUS:-status}"
sudo mkdir -p "$DEST/${PATH_STATE:-state}"
sudo mkdir -p "$DEST/${PATH_BACKUP:-backup}"

echo "[setup] Setup complete. Running $DEST/installicious.sh"
cd "$DEST"
# We're already root (setup.sh was invoked via sudo). Re-sudo would overwrite
# $SUDO_USER to "root", which would lose track of the real user that
# install-bash and friends need to configure dotfiles for.
bash "$DEST/installicious.sh"
