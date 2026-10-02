#!/bin/bash
# commands/init.md, commands/doctor.md and commands/stats.md hand the whole typed
# $ARGUMENTS string through to their target script as ONE quoted argument to a
# synthetic --arguments-string flag (#439), rather than splitting it themselves inside
# a `bash -c '...'` wrapper (#405's original fix for #278). jit-init.sh, jit-doctor.sh
# and jit-stats.sh each do their own `--base DIR`-style parsing (grep for `--base)` in
# any of them: `[ $# -ge 2 ] || need_value "$1"; BASE="$2"; shift 2`), so $ARGUMENTS is
# genuinely meant to carry more than one shell word -- a plain `"$ARGUMENTS"` would
# break `--base <dir>` by handing the script one combined argument instead of two. The
# splitting itself now happens INSIDE each script, behind its own `--arguments-string`
# flag, because the script is always invoked as `bash .../scripts/X.sh`, which
# guarantees a real bash regardless of what shell is running the command body (#405) --
# and because the body's own first words can then literally be the script invocation,
# which is what lets the allowed-tools grant name this one script instead of holding
# `Bash` (every shell command) or `Bash(bash -c:*)` (every bash -c invocation) (#439).
#
# This suite tests two things separately:
#   A. the command body itself: extracted from the real markdown fence, run against a
#      stub CLAUDE_PLUGIN_ROOT, proving the body hands $ARGUMENTS through untouched --
#      as one quoted word -- to `--arguments-string`, under both bash and zsh.
#   B. the splitting contract a stub replicates from each real script's own
#      `--arguments-string` handling: that it reaches the stub as separate words
#      (the #278 property), that a typed glob is never expanded against the cwd, and
#      that an empty or unset $ARGUMENTS does not crash under `set -u`.
#
# jit-drive: none -- ok()/bad() below are local, one-line pass/fail counters over
# `grep -qF NEEDLE <<<"$out"` reads of a single stub-script capture each, the same shape
# test-commands.sh already declares `none` for; nothing here is a captured-output
# assertion of the shared contains/lacks/marker shape test-assertion-helpers.sh drives.
#
# Usage: bash tests/test-arguments-splicing-278.sh

set -uo pipefail

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
}

# Pulls the first ```bash ... ``` fence out of a command markdown file.
extract_fence() {
  awk '
    /^```bash[[:space:]]*$/ { infence = 1; next }
    infence && /^```[[:space:]]*$/ { exit }
    infence { print }
  ' "$1"
}

ROOT="$(mktemp -d 2> /dev/null || mktemp -d -t jit278)"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

STUB_ROOT="$ROOT/plugin"
mkdir -p "$STUB_ROOT/scripts"

# A stub in place of the real jit-init.sh/jit-doctor.sh/jit-stats.sh: replicates the
# same --arguments-string splitting contract the real scripts each carry (one quoted
# string in, IFS=' ' read -a, spliced back onto "$@"), then dumps every resulting
# argument, one per line, so the count and the exact text of each word is checkable.
cat > "$STUB_ROOT/scripts/jit-init.sh" << 'STUB'
#!/bin/bash
set -u
if [ "${1:-}" = "--arguments-string" ]; then
  IFS=' ' read -r -a _split <<< "${2:-}"
  shift 2
  set -- "${_split[@]+"${_split[@]}"}" "$@"
fi
printf 'ARGC=%s\n' "$#"
i=0
for a in "$@"; do
  i=$((i + 1))
  printf 'ARG%s=[%s]\n' "$i" "$a"
done
STUB
cp "$STUB_ROOT/scripts/jit-init.sh" "$STUB_ROOT/scripts/jit-doctor.sh"
cp "$STUB_ROOT/scripts/jit-init.sh" "$STUB_ROOT/scripts/jit-stats.sh"
chmod +x "$STUB_ROOT/scripts/jit-init.sh" "$STUB_ROOT/scripts/jit-doctor.sh" "$STUB_ROOT/scripts/jit-stats.sh"

# A directory to run the fence FROM, seeded with files a stray glob would pick up. Any
# command body still relying on plain unquoted expansion will splice these in.
CWD="$ROOT/cwd"
mkdir -p "$CWD"
: > "$CWD/decoy-one.txt"
: > "$CWD/decoy-two.txt"

# $1 command file basename
check_command_body() {
  local name="$1" file out
  file="$COMMANDS/$name"

  local fence="$ROOT/fence-$name.sh"
  extract_fence "$file" > "$fence"
  if [ ! -s "$fence" ]; then
    bad "commands/$name has a non-empty bash fence to extract"
    return
  fi

  echo "--- commands/$name body ---"

  # A. the split case: --base carries a value as its own word -- reaches the stub as
  # ONE combined argument to --arguments-string; the stub's own splitting (replicated
  # from the real script) then turns it into two.
  out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='--base /some/project/.claude/jit-context' bash "$fence" 2>&1)"
  # Here-string, never a pipe: `| grep -q` exits the instant it matches and the writer on
  # the left takes SIGPIPE, which under `pipefail` reports the OPPOSITE of what was found
  # once output is long enough (#56, the reason test-cross-tree-write-231.sh does the
  # same). $out here is small, but the shape is what the structural guard in
  # test-assertion-helpers.sh flags regardless of size.
  if grep -qF 'ARGC=2' <<< "$out" \
    && grep -qF 'ARG1=[--base]' <<< "$out" \
    && grep -qF 'ARG2=[/some/project/.claude/jit-context]' <<< "$out"; then
    ok "commands/$name: \"--base DIR\" reaches the script as two separate words"
  else
    bad "commands/$name: \"--base DIR\" reaches the script as two separate words" "got: $out"
  fi

  # B. the splicing case (#278): a typed value carrying a bare glob must reach the
  # script as that literal text -- not expand against whatever files happen to sit in
  # the directory the command runs from.
  out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='--base decoy-*' bash "$fence" 2>&1)"
  if grep -qF 'ARGC=2' <<< "$out" \
    && grep -qF 'ARG2=[decoy-*]' <<< "$out"; then
    ok "commands/$name: a typed glob is not expanded against the cwd"
  else
    bad "commands/$name: a typed glob is not expanded against the cwd" "got: $out"
  fi

  # C. the common case: no arguments at all (bare `/jit-context:init`, `/jit-context:doctor`).
  # Claude Code substitutes the body's bare $ARGUMENTS with literal text BEFORE the shell
  # ever runs anything (#439) -- with nothing typed, that text is the empty string, never
  # an absent token -- so the only realistic zero-argument state to drive here is ARGUMENTS
  # literally empty, under `set -u` so a zero-element array expansion regression (a classic
  # bash < 4.4 trap) is loud instead of environment-dependent. An entirely UNSET ARGUMENTS
  # is deliberately not driven: that was a real runtime state under the previous
  # "${ARGUMENTS:-}" design (a real shell variable Claude Code supplied out of band, which
  # could in principle be absent), but it cannot occur under this one -- $ARGUMENTS is
  # resolved to text before this script ever starts, not read from the environment at all.
  out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='' bash -u "$fence" 2>&1)"
  if grep -qF 'ARGC=0' <<< "$out"; then
    ok "commands/$name: empty \$ARGUMENTS under set -u still runs with zero extra args"
  else
    bad "commands/$name: empty \$ARGUMENTS under set -u still runs with zero extra args" "got: $out"
  fi

  # D. #405: a slash command's fenced body is not guaranteed to run under bash. The
  # body itself no longer does any `read -a` of its own (that moved into the script,
  # which is always invoked explicitly as `bash .../scripts/X.sh` regardless of what
  # shell runs this fenced body) -- so this now proves #405 cannot regress at the body
  # layer at all, rather than merely surviving it. Skipped gracefully (not silently)
  # when no zsh is installed to run it against.
  if command -v zsh > /dev/null 2>&1; then
    out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='--base /some/project/.claude/jit-context' zsh "$fence" 2>&1)"
    if grep -qF 'ARGC=2' <<< "$out" \
      && grep -qF 'ARG1=[--base]' <<< "$out" \
      && grep -qF 'ARG2=[/some/project/.claude/jit-context]' <<< "$out"; then
      ok "commands/$name: \"--base DIR\" still reaches the script as two words when zsh runs this body"
    else
      bad "commands/$name: \"--base DIR\" still reaches the script as two words when zsh runs this body" "got: $out"
    fi
  else
    echo "  SKIP: commands/$name zsh check -- no zsh on this machine"
  fi
}

check_command_body "init.md"
check_command_body "doctor.md"
check_command_body "stats.md"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
