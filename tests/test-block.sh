#!/bin/bash
# Tests for lib/block.sh — managed-block file edits with permission preservation.
# Critical regression coverage: a previous version of block_ensure used mktemp
# (mode 0600) + mv -f without restoring the original mode, which left /etc/profile
# unreadable to non-root users and broke login. This suite locks that behavior.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/block.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

START="# ===== test BLOCK begin ====="
END="# ===== test BLOCK end ====="

# ===========================================================================
echo "=== Test 1: block_ensure on a brand-new file uses mode 0644 ==="
target="$TMPDIR/new.txt"
echo "hello" | block_ensure "$target" "$START" "$END"
[[ -f $target ]] && ok "file created"
chkeq "default mode 644" "$(stat -c '%a' "$target")" "644"
grep -qxF "$START" "$target" && ok "start marker present"
grep -qxF "$END"   "$target" && ok "end marker present"

# ===========================================================================
echo
echo "=== Test 2: block_ensure preserves mode 0644 on an existing file ==="
target="$TMPDIR/profile-like.txt"
printf '# original line\nexport FOO=bar\n' > "$target"
chmod 644 "$target"
echo "added by block_ensure" | block_ensure "$target" "$START" "$END"
chkeq "mode preserved as 644" "$(stat -c '%a' "$target")" "644"
grep -qxF "$START" "$target" && ok "block appended" || fail "block not appended"
grep -q '^# original line$' "$target" && ok "original content preserved"

# ===========================================================================
echo
echo "=== Test 3: block_ensure preserves a non-default mode (round-trip) ==="
# Some system files use stricter modes. block_ensure must not promote OR
# demote them — the file should round-trip exactly. The test compares the
# mode AFTER chmod to the mode AFTER block_ensure so it works on platforms
# (e.g. Windows MSYS) where chmod 640 doesn't fully take effect.
target="$TMPDIR/strict.txt"
printf 'secret stuff\n' > "$target"
chmod 640 "$target"
initial=$(stat -c '%a' "$target")
echo "managed content" | block_ensure "$target" "$START" "$END"
chkeq "mode round-trips" "$(stat -c '%a' "$target")" "$initial"

# ===========================================================================
echo
echo "=== Test 4: block_ensure is idempotent (re-run yields identical file) ==="
target="$TMPDIR/idem.txt"
printf 'baseline\n' > "$target"
chmod 644 "$target"
echo "block payload" | block_ensure "$target" "$START" "$END"
hash1=$(sha256sum "$target" | awk '{print $1}')
echo "block payload" | block_ensure "$target" "$START" "$END"
hash2=$(sha256sum "$target" | awk '{print $1}')
chkeq "second run identical" "$hash1" "$hash2"
chkeq "still mode 644" "$(stat -c '%a' "$target")" "644"

# ===========================================================================
echo
echo "=== Test 5: block_ensure replaces existing block content in place ==="
target="$TMPDIR/replace.txt"
printf 'before\n' > "$target"
chmod 644 "$target"
echo "first version" | block_ensure "$target" "$START" "$END"
echo "second version" | block_ensure "$target" "$START" "$END"
grep -qxF "second version" "$target" && ok "new content present"
grep -qxF "first version"  "$target" && fail "old content leaked" || ok "old content stripped"
chkeq "still mode 644" "$(stat -c '%a' "$target")" "644"

# ===========================================================================
echo
echo "=== Test 6: block_remove preserves mode ==="
target="$TMPDIR/remove.txt"
printf 'keepme\n' > "$target"
chmod 644 "$target"
echo "to be removed" | block_ensure "$target" "$START" "$END"
chkeq "after ensure: mode 644" "$(stat -c '%a' "$target")" "644"
block_remove "$target" "$START" "$END"
chkeq "after remove: mode 644" "$(stat -c '%a' "$target")" "644"
grep -qxF "$START" "$target" && fail "marker should be gone" || ok "block removed"
grep -q '^keepme$' "$target" && ok "non-block content preserved"

# ===========================================================================
echo
echo "=== Test 7: regression — /etc/profile-shaped file stays world-readable ==="
# Simulates the bug that broke login: an existing root:root mode-0644 file
# must round-trip through block_ensure with mode 0644 intact (NOT 0600 from
# mktemp's default).
target="$TMPDIR/profile.txt"
printf '# ~/.profile equivalent\nPATH=/usr/local/bin:/usr/bin\n' > "$target"
chmod 644 "$target"
echo "MOTD launcher block" | block_ensure "$target" "$START" "$END"
mode=$(stat -c '%a' "$target")
[[ $mode == "644" ]] && ok "mode 644 preserved (would be 600 under the bug)" \
                     || fail "mode is $mode, would lock out non-root users"

echo
echo "=== Done ==="
