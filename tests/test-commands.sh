#!/bin/bash
# Tests for commands/ -- the slash commands this plugin ships for a marketplace install,
# where $CLAUDE_PLUGIN_ROOT is the only path into the plugin cache a user can reach (#202,
# #261). Nothing else exercises these files: they are not sourced, not hooked, not read
# by rebuild-tsv.sh -- a session just resolves the frontmatter and runs the body. So this
# suite reads them the same way: parse the frontmatter, and grep the body for the
# resolution the file exists to provide.
#
# Usage: bash tests/test-commands.sh

set -uo pipefail

# jit-drive: none -- ok()/bad() below are local, one-line pass/fail counters over a single
# static file each; nothing here is a captured-output assertion of the shared
# contains/lacks/marker shape test-assertion-helpers.sh drives.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS="$REPO/commands"

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
  return 0
}

# $1 command file basename (e.g. doctor.md), $2 script it must resolve through
# ${CLAUDE_PLUGIN_ROOT}, i.e. the *-hook.sh/*.sh script under scripts/.
check_command() {
  local name="$1" script="$2" file
  file="$COMMANDS/$name"

  if [ -f "$file" ]; then
    ok "commands/$name exists"
  else
    bad "commands/$name exists" "no such file: $file"
    return
  fi

  local firstline
  firstline="$(head -n1 "$file")"
  if [ "$firstline" = "---" ]; then
    ok "commands/$name opens with a frontmatter fence"
  else
    bad "commands/$name opens with a frontmatter fence" "got: $firstline"
  fi

  if grep -qE '^description:' "$file"; then
    ok "commands/$name declares a description"
  else
    bad "commands/$name declares a description"
  fi

  # #439: a bare `allowed-tools: Bash` grants every shell command, which the
  # Anthropic directory holds as unrestricted shell access. The narrowed form names this
  # one script, invoked explicitly through bash so the grant text and the body's first
  # words are byte-identical. #456: ${CLAUDE_PLUGIN_ROOT} is quoted in both the body and
  # the grant -- a plugin root containing a space otherwise splits into several words
  # before the script can parse its own flags, and the grant has to stay byte-identical
  # to the quoted body for the Bash tool's permission check to match it (verified against
  # a real `claude -p` run: an unquoted grant against a quoted body was DENIED).
  local want_grant="allowed-tools: Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/$script\":*)"
  if grep -qF "$want_grant" "$file"; then
    ok "commands/$name narrows allowed-tools to bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/$script\""
  else
    bad "commands/$name narrows allowed-tools to bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/$script\"" \
      "wanted: $want_grant" "got: $(grep -E '^allowed-tools:' "$file")"
  fi

  # The one line this whole suite exists to guard: a marketplace install has no other
  # path into the plugin cache (#202), so the body must resolve through the variable
  # rather than name a clone-relative or manual-install path.
  if grep -qF '${CLAUDE_PLUGIN_ROOT}' "$file"; then
    ok "commands/$name's body resolves through \${CLAUDE_PLUGIN_ROOT}"
  else
    bad "commands/$name's body resolves through \${CLAUDE_PLUGIN_ROOT}" \
      "a marketplace install has no other reachable path (#202)"
  fi

  if grep -qF "scripts/$script" "$file"; then
    ok "commands/$name names scripts/$script"
  else
    bad "commands/$name names scripts/$script"
  fi

  # #456: the grant above and the fenced body's own invocation have to be byte-identical
  # for the Bash tool's permission check to match the grant against the literal command
  # text it sees -- quoting only the grant, or only the body, reproduces the bug (verified
  # with a real `claude -p` run: an unquoted grant against a quoted body was DENIED). The
  # two checks above are substring-only and would both still pass if the body alone
  # regressed to the unquoted form while the grant stayed quoted, since the grant line
  # itself also contains this substring -- so this counts occurrences: one in the grant,
  # one in the body, both quoted the same way, or this test does not tell the two cases
  # apart.
  local want_invocation="bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/$script\""
  local invocation_count
  invocation_count="$(grep -cF "$want_invocation" "$file")"
  if [ "$invocation_count" -ge 2 ]; then
    ok "commands/$name's body invokes bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/$script\", byte-identical to the grant"
  else
    bad "commands/$name's body invokes bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/$script\", byte-identical to the grant" \
      "wanted 2+ occurrences (grant and body) of: $want_invocation" \
      "got $invocation_count occurrence(s): $(grep -F "scripts/$script" "$file")"
  fi

  # $ARGUMENTS passthrough -- both commands take flags a user or the session may supply
  # (jit-doctor.sh's --base, jit-init.sh's --base), and a command file that hardcodes no
  # args silently drops them.
  if grep -qF '$ARGUMENTS' "$file"; then
    ok "commands/$name passes \$ARGUMENTS through"
  else
    bad "commands/$name passes \$ARGUMENTS through"
  fi
}

echo "=== commands/doctor.md ==="
check_command "doctor.md" "jit-doctor.sh"

echo ""
echo "=== commands/init.md ==="
check_command "init.md" "jit-init.sh"

echo ""
echo "=== commands/stats.md ==="
check_command "stats.md" "jit-stats.sh"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
