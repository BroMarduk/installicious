#!/bin/bash
# Sanity check that feature-bash.sh's match strings actually match the
# default Pi OS .bashrc lines. Re-uses the same string definitions.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMP=$(mktemp)
trap "rm -f $TMP" EXIT

# Default Pi OS root .bashrc lines (subset). Use literal heredoc (no expansion).
cat > "$TMP" <<'BASHRC'
# ~/.bashrc: executed by bash(1) for non-login shells.
# PS1 is set in /etc/profile.
# PS1='${debian_chroot:+($debian_chroot)}\h:\w\$ '
# umask 022
# export LS_OPTIONS='--color=auto'
# eval "$(dircolors)"
# alias ls='ls $LS_OPTIONS'
# alias ll='ls $LS_OPTIONS -l'
# alias l='ls $LS_OPTIONS -lA'
# alias rm='rm -i'
# alias cp='cp -i'
# alias mv='mv -i'
BASHRC

# Reproduce the exact strings from feature-bash.sh (must match its quoting).
ROOT_PS1_OLD="# PS1='\${debian_chroot:+(\$debian_chroot)}\\h:\\w\\\$ '"
ROOT_PS1_NEW="PS1='\${debian_chroot:+(\$debian_chroot)}\\[\\033[01;31m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\\$ '"

ROOT_PAIRS=(
  "# export LS_OPTIONS='--color=auto'"     "export LS_OPTIONS='--color=auto'"
  "# eval \"\$(dircolors)\""               "eval \"\$(dircolors)\""
  "# alias ls='ls \$LS_OPTIONS'"            "alias ls='ls \$LS_OPTIONS'"
  "# alias ll='ls \$LS_OPTIONS -l'"         "alias ll='ls \$LS_OPTIONS -l'"
  "# alias l='ls \$LS_OPTIONS -lA'"         "alias l='ls \$LS_OPTIONS -lA'"
  "# alias rm='rm -i'"                      "alias rm='rm -i'"
  "# alias cp='cp -i'"                      "alias cp='cp -i'"
  "# alias mv='mv -i'"                      "alias mv='mv -i'"
)

ok()   { echo "  OK $1"; }
fail() { echo "  FAIL $1"; }

if grep -qFx -- "$ROOT_PS1_OLD" "$TMP"; then
  ok "ROOT_PS1_OLD matches"
else
  fail "ROOT_PS1_OLD does NOT match"
  echo "  expected: $ROOT_PS1_OLD"
  echo "  actual lines containing PS1:"
  grep PS1 "$TMP" | sed 's/^/    /'
fi

i=0
while [[ $i -lt ${#ROOT_PAIRS[@]} ]]; do
  from="${ROOT_PAIRS[$i]}"
  if grep -qFx -- "$from" "$TMP"; then
    ok "matches: $from"
  else
    fail "MISS: $from"
  fi
  i=$((i + 2))
done

# Now apply replacement and verify
echo
echo "--- after applying transforms ---"
TMP2=$(mktemp)
trap 'rm -f $TMP $TMP2' EXIT
cp "$TMP" "$TMP2"

AWK_FROM="$ROOT_PS1_OLD" AWK_TO="$ROOT_PS1_NEW" awk '$0 == ENVIRON["AWK_FROM"] {print ENVIRON["AWK_TO"]; next} {print}' "$TMP2" > "$TMP2.x" && mv "$TMP2.x" "$TMP2"

i=0
while [[ $i -lt ${#ROOT_PAIRS[@]} ]]; do
  from="${ROOT_PAIRS[$i]}"
  to="${ROOT_PAIRS[$((i+1))]}"
  AWK_FROM="$from" AWK_TO="$to" awk '$0 == ENVIRON["AWK_FROM"] {print ENVIRON["AWK_TO"]; next} {print}' "$TMP2" > "$TMP2.x" && mv "$TMP2.x" "$TMP2"
  i=$((i + 2))
done

cat "$TMP2"
