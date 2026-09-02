#!/bin/bash
# commands/init.md and commands/doctor.md run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<x>.sh"
# $ARGUMENTS` with $ARGUMENTS bare and unquoted (#278). jit-init.sh and jit-doctor.sh both
# parse `--base DIR` as two separate words (scripts/jit-init.sh, scripts/jit-doctor.sh --
# grep for `--base)` in either: `[ $# -ge 2 ] || need_value "$1"; BASE="$2"; shift 2`), so
# $ARGUMENTS is genuinely meant to carry more than one shell word -- a plain `"$ARGUMENTS"`
# would break `--base <dir>` by handing the script one combined argument instead of two.
#
# The fix has to make that splitting explicit (an array built with `read -a`) rather than
# lean on bash's own unquoted-expansion word-splitting, because unquoted expansion does two
# things at once and only one of them is wanted: it splits on IFS (wanted, for --base DIR)
# AND performs pathname (glob) expansion on the result (never wanted -- a typed value with
# a `*` or `?` in it should reach the script as that literal text, not as however many
# files happen to be lying around in whatever directory the command runs from). That
# second half is the actual "admits" in #278: an unquoted `$ARGUMENTS` containing a glob
# character silently splices in extra, unintended arguments when matching files exist,
# and does it differently on every machine depending on what is in the cwd at the time.
#
# This suite extracts the real bash fence from each command file and runs it against a
# stub CLAUDE_PLUGIN_ROOT, so it is testing the actual body Claude Code would execute, not
# a paraphrase of it.
#
# Usage: bash tests/test-arguments-splicing-278.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS="$REPO/commands"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

# Pulls the first ```bash ... ``` fence out of a command markdown file.
extract_fence() {
  awk '
    /^```bash[[:space:]]*$/ { infence = 1; next }
    infence && /^```[[:space:]]*$/ { exit }
    infence { print }
  ' "$1"
}

ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t jit278)"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

STUB_ROOT="$ROOT/plugin"
mkdir -p "$STUB_ROOT/scripts"

# A stub in place of the real jit-init.sh/jit-doctor.sh: dumps every argument it received,
# one per line, so the count and the exact text of each word is checkable.
cat > "$STUB_ROOT/scripts/jit-init.sh" <<'STUB'
#!/bin/bash
printf 'ARGC=%s\n' "$#"
i=0
for a in "$@"; do
  i=$((i + 1))
  printf 'ARG%s=[%s]\n' "$i" "$a"
done
STUB
cp "$STUB_ROOT/scripts/jit-init.sh" "$STUB_ROOT/scripts/jit-doctor.sh"
chmod +x "$STUB_ROOT/scripts/jit-init.sh" "$STUB_ROOT/scripts/jit-doctor.sh"

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

  # A. the split case: --base carries a value as its own word.
  out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='--base /some/project/.claude/jit-context' bash "$fence" 2>&1)"
  if printf '%s\n' "$out" | grep -qF 'ARGC=2' && \
     printf '%s\n' "$out" | grep -qF 'ARG1=[--base]' && \
     printf '%s\n' "$out" | grep -qF 'ARG2=[/some/project/.claude/jit-context]'; then
    ok "commands/$name: \"--base DIR\" reaches the script as two separate words"
  else
    bad "commands/$name: \"--base DIR\" reaches the script as two separate words" "got: $out"
  fi

  # B. the splicing case (#278): a typed value carrying a bare glob must reach the script
  # as that literal text -- not expand against whatever files happen to sit in the
  # directory the command runs from.
  out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='--base decoy-*' bash "$fence" 2>&1)"
  if printf '%s\n' "$out" | grep -qF 'ARGC=2' && \
     printf '%s\n' "$out" | grep -qF 'ARG2=[decoy-*]'; then
    ok "commands/$name: a typed glob is not expanded against the cwd"
  else
    bad "commands/$name: a typed glob is not expanded against the cwd" "got: $out"
  fi

  # C. the common case: no arguments at all (bare `/jit-context:init`, `/jit-context:doctor`).
  # An empty ARRAY expansion (`"${arr[@]}"` on a zero-element array) is a classic `set -u`
  # trap on bash < 4.4, and ARGUMENTS itself may be unset rather than merely empty -- both
  # are driven, with `set -u` on so a regression here is loud instead of environment-
  # dependent.
  out="$(cd "$CWD" && CLAUDE_PLUGIN_ROOT="$STUB_ROOT" ARGUMENTS='' bash -u "$fence" 2>&1)"
  if printf '%s\n' "$out" | grep -qF 'ARGC=0'; then
    ok "commands/$name: empty \$ARGUMENTS under set -u still runs with zero extra args"
  else
    bad "commands/$name: empty \$ARGUMENTS under set -u still runs with zero extra args" "got: $out"
  fi

  out="$(cd "$CWD" && env -u ARGUMENTS CLAUDE_PLUGIN_ROOT="$STUB_ROOT" bash -u "$fence" 2>&1)"
  if printf '%s\n' "$out" | grep -qF 'ARGC=0'; then
    ok "commands/$name: unset \$ARGUMENTS under set -u still runs with zero extra args"
  else
    bad "commands/$name: unset \$ARGUMENTS under set -u still runs with zero extra args" "got: $out"
  fi
}

check_command_body "init.md"
check_command_body "doctor.md"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
