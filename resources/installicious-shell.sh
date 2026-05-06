# /etc/profile.d/installicious.sh
#
# Defines an `installicious` shell function wrapper for the installicious
# entry script. Use it INSTEAD of `sudo bash installicious.sh` when you
# want shell-config changes (new aliases, prompt, etc.) to take effect
# immediately in your current shell.
#
# How it works:
#   1. The wrapper invokes /etc/installicious/installicious.sh under sudo.
#   2. When a feature changes shell config (e.g. the bash customizer),
#      it sets a flag at /etc/installicious/state/reload-shell.
#   3. When installicious exits (and didn't reboot), the wrapper sees the
#      flag, removes it, and `exec bash -l` so your interactive shell is
#      replaced with a fresh login bash that picks up the new config.
#
# When a reboot is requested (rc=255), the wrapper does NOT exec — the
# new login after the reboot starts with fresh config naturally.
#
# Non-interactive shells skip the function definition; only interactive
# logins get it.

# Skip for non-interactive shells (cron, scp, etc.).
[ -z "$PS1" ] && return 0
case $- in *i*) ;; *) return 0 ;; esac

installicious() {
  local script="/etc/installicious/installicious.sh"
  if [ ! -f "$script" ]; then
    echo "installicious: $script not found" >&2
    return 127
  fi
  sudo bash "$script" "$@"
  local rc=$?

  local reload_flag="/etc/installicious/state/reload-shell"
  if [ $rc -ne 255 ] && [ -f "$reload_flag" ]; then
    sudo rm -f "$reload_flag"
    echo
    echo "[installicious] Reloading shell to pick up the new config..."
    exec bash -l
  fi
  return $rc
}
