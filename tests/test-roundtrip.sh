#!/bin/bash
# Round-trip smoke test for git/pip packages and pkupd/zram features.
# install -> uninstall -> install verifies state is fully restored each cycle.
#
# Stubs apt-get/dpkg/dpkg-query/systemctl/swapoff/sudo so this can run on the
# dev machine without touching the real system. Redirects /etc and /sys writes
# into a tempdir.

# Run from project root regardless of caller's cwd.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

STUB=$(mktemp -d)
TMPSTATUS=$(mktemp -d)
TMPBACKUP=$(mktemp -d)
TMPETC=$(mktemp -d)
TMPSYS=$(mktemp -d)

cp config/installicious.config config/installicious.config.bak
trap "mv -f config/installicious.config.bak config/installicious.config; rm -rf $STUB $TMPSTATUS $TMPBACKUP $TMPETC $TMPSYS" EXIT

sed -i "s|^PATH_STATUS=.*|PATH_STATUS=\"$TMPSTATUS\"|" config/installicious.config
sed -i "s|^PATH_BACKUP=.*|PATH_BACKUP=\"$TMPBACKUP\"|" config/installicious.config

# Redirect feature-zram's /etc paths to a sandbox so the script's own [[ -f ]]
# checks see the same files our sudo stub creates. Production paths are the
# defaults inside the script; these overrides are test-only.
export ZRAMSWAP_DEFAULTS="$TMPETC/default/zramswap"
export ZRAM_GENERATOR_CONF="$TMPETC/systemd/zram-generator.conf"
export RPI_SWAP_DROPIN="$TMPETC/rpi/swap.conf.d/99-installicious.conf"

# ---- stubs ----
cat > "$STUB/dpkg-query" <<EOF
#!/bin/bash
pkg=\$3
[[ -f "$STUB/.installed_\$pkg" ]] && { echo "install ok installed"; exit 0; }
exit 1
EOF
cat > "$STUB/dpkg" <<EOF
#!/bin/bash
if [[ \$1 == "-l" ]]; then
  pkg=\$2
  [[ -f "$STUB/.installed_\$pkg" ]] && { echo "ii  \$pkg  1.0  all"; exit 0; }
  exit 1
fi
exit 0
EOF
cat > "$STUB/apt-get" <<EOF
#!/bin/bash
[[ -f "$STUB/.fail" ]] && exit 7
op=\$1
shift
if [[ \$op == install ]]; then
  for arg in "\$@"; do
    case "\$arg" in --*) ;; *) touch "$STUB/.installed_\$arg" ;; esac
  done
elif [[ \$op == "--yes" ]]; then
  for arg in "\$@"; do
    case "\$arg" in --*|autoremove) ;; *) rm -f "$STUB/.installed_\$arg" ;; esac
  done
fi
exit 0
EOF
# systemctl stub: drop --flag args before reading the unit name.
cat > "$STUB/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$STUB/.calls"
sub=\$1; shift
while [[ \$# -gt 0 && \$1 == --* ]]; do shift; done
unit=\$1
case "\$sub" in
  is-enabled|is-active) [[ -f "$STUB/.svc_\${unit}_enabled" ]] && exit 0 || exit 1 ;;
  enable)               touch "$STUB/.svc_\${unit}_enabled" ;;
  disable)              rm -f "$STUB/.svc_\${unit}_enabled" ;;
  list-unit-files)      exit 0 ;;
esac
exit 0
EOF
cat > "$STUB/swapoff" <<EOF
#!/bin/bash
exit 0
EOF
cat > "$STUB/getent" <<EOF
#!/bin/bash
exit 1
EOF
# sudo: passthrough; rewrite /etc and /sys paths in tee/mkdir/rm/cp.
cat > "$STUB/sudo" <<SUDO_EOF
#!/bin/bash
rewrite_paths() {
  local out=()
  for arg in "\$@"; do
    case "\$arg" in
      /etc/*) arg="$TMPETC\${arg#/etc}" ;;
      /sys/*) arg="$TMPSYS\${arg#/sys}" ;;
    esac
    out+=("\$arg")
  done
  printf '%s\n' "\${out[@]}"
}
case "\$1" in
  tee|mkdir|rm|cp)
    cmd=\$1; shift
    mapfile -t newargs < <(rewrite_paths "\$@")
    for f in "\${newargs[@]}"; do
      [[ \$f == -* ]] && continue
      [[ \$cmd == mkdir ]] && continue
      [[ \$cmd == rm ]] && continue
      mkdir -p "\$(dirname "\$f")" 2>/dev/null
    done
    exec "\$cmd" "\${newargs[@]}"
    ;;
  *) exec env "\$@" ;;
esac
SUDO_EOF
chmod +x "$STUB"/*

export PATH="$STUB:$PATH"
export LIB_LOG_USE_SUDO=0
# /dev/zram0 doesn't exist in this stub harness (no zram kernel module).
# Tell feature-zram to skip the live-state verification so it doesn't
# request a reboot just because /sys/block/zram0/* are missing.
export ZRAM_SKIP_LIVE_VERIFY=true

ok()       { echo "  OK $1"; }
fail()     { echo "  FAIL $1"; }
chkf()     { [[ -f "$2" ]] && ok "$1" || fail "$1 (expected file: $2)"; }
chknof()   { [[ ! -f "$2" ]] && ok "$1" || fail "$1 (file still present: $2)"; }
chkrc()    { [[ $2 -eq 0 ]] && ok "$1" || fail "$1 (rc=$2)"; }
chkgrep()  { local d="$1" p="$2" f="$3"; grep -q "$p" "$f" 2>/dev/null && ok "$d" || fail "$d (pat=$p file=$f)"; }
run()      { ( bash "$@" ) >/dev/null 2>&1; }

# ===========================================================================
echo "=== Test 1: install-git round-trip (git not pre-installed) ==="
run packages/package-git.sh; rc=$?
chkrc "install exit 0" $rc
chkf "git installed" "$STUB/.installed_git"
chkgrep "PRE_INSTALLED=false recorded" "^GIT_FW_PRE_INSTALLED=\"false\"" "$TMPSTATUS/git.status"

run packages/package-git.sh --uninstall; rc=$?
chkrc "uninstall exit 0" $rc
chknof "git removed" "$STUB/.installed_git"
chkgrep "FW_STATE=uninstalled" "^GIT_FW_STATE=\"uninstalled\"" "$TMPSTATUS/git.status"

run packages/package-git.sh
chkf "re-install: git back" "$STUB/.installed_git"
chkgrep "FW_STATE=completed" "^GIT_FW_STATE=\"completed\"" "$TMPSTATUS/git.status"

run packages/package-git.sh --uninstall
chknof "re-uninstall: git gone" "$STUB/.installed_git"

# ===========================================================================
echo
echo "=== Test 2: install-git (git WAS pre-installed) — package preserved ==="
rm -f "$TMPSTATUS"/git.status
touch "$STUB/.installed_git"
run packages/package-git.sh
chkgrep "PRE_INSTALLED=true recorded" "^GIT_FW_PRE_INSTALLED=\"true\"" "$TMPSTATUS/git.status"

run packages/package-git.sh --uninstall
chkf "uninstall did NOT remove pre-existing git" "$STUB/.installed_git"
rm -f "$STUB/.installed_git"
rm -f "$TMPSTATUS"/git.status

# ===========================================================================
echo
echo "=== Test 3: install-pip round-trip ==="
run packages/package-pip.sh
chkf "python3-pip installed" "$STUB/.installed_python3-pip"
# Pre-state is keyed by package name (PYTHON3_PIP_…), not installer name —
# installer_apt supports multi-package installers where this distinction matters.
chkgrep "PRE_INSTALLED=false" "^PYTHON3_PIP_FW_PRE_INSTALLED=\"false\"" "$TMPSTATUS/pip.status"

run packages/package-pip.sh --uninstall
chknof "python3-pip removed" "$STUB/.installed_python3-pip"
chkgrep "PIP_FW_STATE=uninstalled" "^PIP_FW_STATE=\"uninstalled\"" "$TMPSTATUS/pip.status"

run packages/package-pip.sh
chkf "re-install" "$STUB/.installed_python3-pip"
run packages/package-pip.sh --uninstall
chknof "re-uninstall" "$STUB/.installed_python3-pip"

# ===========================================================================
echo
echo "=== Test 4: install-pkupd uninstall is no-op + mark ==="
> "$STUB/.calls"
run features/feature-pkupd.sh
chkgrep "FW_STATE=completed" "^PKUPD_FW_STATE=\"completed\"" "$TMPSTATUS/pkupd.status"

OUT=$(bash features/feature-pkupd.sh --uninstall 2>&1)
echo "$OUT" | grep -q "not reversible" && ok "uninstall logged 'not reversible'" || fail "uninstall did not log 'not reversible'"
chkgrep "FW_STATE=uninstalled" "^PKUPD_FW_STATE=\"uninstalled\"" "$TMPSTATUS/pkupd.status"

# ===========================================================================
echo
echo "=== Test 5: zram round-trip (package + feature, fresh system) ==="
# Mirrors what the scheduler does: package-zram-tools first (handles the
# apt install + its own pre-state record), then feature-zram (handles
# /dev/zram0 config + non-package pre-state).
rm -rf "$TMPETC"/* 2>/dev/null
rm -f "$TMPSTATUS"/zram.status "$TMPSTATUS"/zram-tools.status
rm -f "$STUB/.installed_zram-tools"

run packages/package-zram-tools.sh; rc=$?
chkrc "package install exit 0" $rc
chkf "zram-tools installed by package" "$STUB/.installed_zram-tools"
chkgrep "package PRE_INSTALLED=false" "^ZRAM_TOOLS_FW_PRE_INSTALLED=\"false\"" "$TMPSTATUS/zram-tools.status"

run features/feature-zram.sh; rc=$?
chkrc "feature install exit 0" $rc
chkf "zramswap config written" "$ZRAMSWAP_DEFAULTS"
chkgrep "PRE_DPHYS=false"         "^ZRAM_FW_PRE_DPHYS_ENABLED=\"false\""        "$TMPSTATUS/zram.status"
chkgrep "SWAP_MANAGER=zram-tools" "^ZRAM_FW_SWAP_MANAGER_USED=\"zram-tools\""   "$TMPSTATUS/zram.status"
# zram-tools pre-state is now tracked by the package, NOT the feature.
grep -q '^ZRAM_FW_PRE_ZRAM_TOOLS_INSTALLED=' "$TMPSTATUS/zram.status" 2>/dev/null \
  && fail "feature should no longer track ZRAM_FW_PRE_ZRAM_TOOLS_INSTALLED" \
  || ok "feature does not duplicate package's pre-state tracking"

# Reverse order on uninstall: feature first (config files), package after
# (apt remove). zram-tools should come out because its pre-state was false.
run features/feature-zram.sh --uninstall; rc=$?
chkrc "feature uninstall exit 0" $rc
chknof "zramswap config removed (we created it)" "$ZRAMSWAP_DEFAULTS"
chkgrep "FW_STATE=uninstalled" "^ZRAM_FW_STATE=\"uninstalled\"" "$TMPSTATUS/zram.status"

run packages/package-zram-tools.sh --uninstall; rc=$?
chkrc "package uninstall exit 0" $rc
chknof "zram-tools removed" "$STUB/.installed_zram-tools"

# Re-install round-trip: package then feature, both come back.
run packages/package-zram-tools.sh
run features/feature-zram.sh
chkf "re-install: zramswap config back" "$ZRAMSWAP_DEFAULTS"
chkf "re-install: zram-tools back" "$STUB/.installed_zram-tools"

# ===========================================================================
echo
echo "=== Test 6: zram preserves pre-existing zram-tools and config ==="
rm -rf "$TMPETC"/*
rm -f "$TMPSTATUS"/zram.status "$TMPSTATUS"/zram-tools.status
rm -f "$STUB/.installed_zram-tools"
mkdir -p "$(dirname "$ZRAMSWAP_DEFAULTS")"
cat > "$ZRAMSWAP_DEFAULTS" <<USER_CFG
# pre-existing user config
PERCENTAGE=25
ALGO=lz4
PRIORITY=5
USER_CFG
touch "$STUB/.installed_zram-tools"
ORIG_CONTENT=$(cat "$ZRAMSWAP_DEFAULTS")

run packages/package-zram-tools.sh
chkgrep "package PRE_INSTALLED=true" "^ZRAM_TOOLS_FW_PRE_INSTALLED=\"true\"" "$TMPSTATUS/zram-tools.status"

run features/feature-zram.sh
chkgrep "config overwritten"  "^PERCENTAGE=50"                            "$ZRAMSWAP_DEFAULTS"

run features/feature-zram.sh --uninstall
run packages/package-zram-tools.sh --uninstall
chkf "pre-existing zram-tools NOT removed" "$STUB/.installed_zram-tools"
chkf "config file restored (not deleted)" "$ZRAMSWAP_DEFAULTS"
RESTORED=$(cat "$ZRAMSWAP_DEFAULTS")
[[ "$RESTORED" == "$ORIG_CONTENT" ]] && ok "config content matches pre-install" || fail "config content does not match pre-install"

# ===========================================================================
echo
echo "=== Test 7: feature-zram preserves dphys-swapfile pre-state ==="
rm -rf "$TMPETC"/*
rm -f "$TMPSTATUS"/zram.status "$TMPSTATUS"/zram-tools.status
rm -f "$STUB"/.svc_*
rm -f "$STUB/.installed_zram-tools"
touch "$STUB/.svc_dphys-swapfile_enabled"

run packages/package-zram-tools.sh
run features/feature-zram.sh
chkgrep "PRE_DPHYS=true recorded" "^ZRAM_FW_PRE_DPHYS_ENABLED=\"true\"" "$TMPSTATUS/zram.status"
chknof "dphys disabled by install" "$STUB/.svc_dphys-swapfile_enabled"

run features/feature-zram.sh --uninstall
chkf "dphys re-enabled by uninstall (pre-state restored)" "$STUB/.svc_dphys-swapfile_enabled"

echo
echo "=== Done ==="
