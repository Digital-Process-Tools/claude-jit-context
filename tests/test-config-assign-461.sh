#!/bin/bash
# #461: jit_load_config assigns each config.env setting through jit_cfg_assign, by its
# literal name, instead of `printf -v "$name"` with a name read from the file. The
# directory validator reads a variable named by a file's own content as the hook
# sourcing that file -- the bare `.` in COMMAND_SCRIPT_NOT_FOLLOWED's file list.
#
# The cost is a second list: a setting some script reads but jit_cfg_assign does not
# name is accepted by the parser and then silently never applied -- this repo's own
# defect class. This suite fails on that. Every `${JIT_CONTEXT_*}`, `${DYNAMIC_RULES_*}`
# or `${DVSI_*}` read anywhere in scripts/ must have an arm in jit_cfg_assign, and the
# function must actually apply one when driven.
#
# Usage: bash tests/test-config-assign-461.sh
#
# jit-drive: none -- this suite scans tracked files for a text shape and calls one function; it defines no assertion helper

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$REPO/scripts/common.sh"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  [ $# -eq 0 ] || echo "    $*"
}

body="$(awk '/^jit_cfg_assign\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$COMMON")"
if [ -n "$body" ]; then
  ok "control: jit_cfg_assign is defined in common.sh"
else
  bad "control: jit_cfg_assign not found in common.sh -- every check below is vacuous"
fi

echo ""
echo "=== every setting a script reads has an arm in jit_cfg_assign ==="
read_names="$(perl -ne 'next if /^\s*#/; print "$1\n" while /\$\{?((?:JIT_CONTEXT|DYNAMIC_RULES|DVSI)_[A-Z0-9_]+)/g' "$REPO"/scripts/*.sh | sort -u)"
n=$(printf '%s\n' "$read_names" | awk 'NF { c++ } END { print c + 0 }')
if [ "$n" -gt 0 ]; then
  ok "control: $n setting name(s) read across scripts/"
else
  bad "control: no setting read anywhere -- the sweep below checks nothing"
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if printf '%s\n' "$body" | grep -q "\"\$1\" = $name \]"; then
    ok "$name has an arm"
  else
    bad "$name is read by a script but jit_cfg_assign never sets it"
  fi
done <<< "$read_names"

echo ""
echo "=== jit_cfg_assign applies a named setting and ignores an unread one ==="
out="$(env -i PATH="$PATH" bash -c 'source "'"$COMMON"'" >/dev/null 2>&1; jit_cfg_assign JIT_CONTEXT_INJECT summary; jit_cfg_assign JIT_CONTEXT_NOT_READ_BY_ANYONE x; printf "%s|%s" "${JIT_CONTEXT_INJECT:-unset}" "${JIT_CONTEXT_NOT_READ_BY_ANYONE:-unset}"' 2> /dev/null)"
if [ "$out" = "summary|unset" ]; then
  ok "JIT_CONTEXT_INJECT applied, an unread name left unset"
else
  bad "expected summary|unset, got: $out"
fi

echo ""
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
