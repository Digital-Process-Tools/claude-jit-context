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

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; return 0; }

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

  if grep -qE '^allowed-tools:[[:space:]]*Bash[[:space:]]*$' "$file"; then
    ok "commands/$name restricts allowed-tools to Bash"
  else
    bad "commands/$name restricts allowed-tools to Bash" "got: $(grep -E '^allowed-tools:' "$file")"
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
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
