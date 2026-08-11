#!/bin/bash
# Tests for the invocation macros — @invocation and @invocation-quoted-arg.
#
# Every rule that has to fire on an INVOCATION rather than a word carries a hand-rolled
# anchor. Four of them have been wrong: the newline alternative that could never fire
# (#6), `git stash push` blocked by a rule written for `git push` (#8), a rule with no
# anchor at all (#8), and this repo's own paths rule matching a scratchpad directory
# (#10). The anchor is the load-bearing part and it is the part nobody can verify by
# reading, which is what this suite replaces.
#
# Both directions for every shape: the command it targets fires, the near-miss is silent.
#
# Usage: bash tests/test-invocation-macro.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/pre-tool-hook.sh"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if printf '%s' "$out" | grep -qF "$want"; then
    ok "$desc"
  else
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}

assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if printf '%s' "$out" | grep -qF "$unwanted"; then
    bad "$desc" "must NOT contain: $unwanted"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  else
    ok "$desc"
  fi
}

# --- A project tree whose rules are written with the macros --------------------
ROOT=$(mktemp -d)
BASE="$ROOT/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual" "$BASE/paths/00-manual" "$BASE/vocabulary/00-manual"

write_entry() {
  # $1 path relative to BASE, $2.. frontmatter lines
  local path="$BASE/$1" l
  shift
  {
    echo "---"
    for l in "$@"; do echo "$l"; done
    echo "---"
    echo ""
    echo "Body for $(basename "$path")."
  } > "$path"
}

rebuild() { CLAUDE_PROJECT_DIR="$ROOT" bash "$REBUILD"; }

write_entry tools/00-manual/git-push.md \
  "title: Open a merge request instead" \
  "tool: Bash" \
  "match: ~@invocation git push" \
  "mode: block"

write_entry tools/00-manual/supertool-arg.md \
  "title: supertool ops take a payload" \
  "tool: Bash" \
  "match: ~@invocation-quoted-arg supertool" \
  "mode: remind"

rebuild >/dev/null 2>&1

echo "=== the macro is expanded at index time, so the hook never sees an @ ==="
INDEX="$(cat "$BASE/tools/00-manual/00-index.tsv")"
assert_not_contains "no unexpanded macro survives into the index" "$INDEX" "@invocation"
assert_contains     "the expansion is a real anchored ERE"        "$INDEX" "(^|[;&|\n] *)"

# --- Driving the real hook ----------------------------------------------------
drive() {
  # $1 command, already JSON-escaped
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null
}

verdict() {
  local out
  out="$(drive "$1")"
  case "$out" in
    *'"decision":"block"'*) echo "BLOCK" ;;
    *'JIT Context'*)        echo "REMIND" ;;
    *)                      echo "silent" ;;
  esac
}

assert_verdict() {
  local desc="$1" cmd="$2" want="$3" got
  got="$(verdict "$cmd")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted $want, got $got — for: $cmd"
  fi
}

echo ""
echo "=== @invocation — command-with-options, both directions ==="
assert_verdict "the bare invocation"           "git push"                            BLOCK
assert_verdict "an option carrying a value"    "git -C /tmp push"                    BLOCK
assert_verdict "a long option"                 "git --no-verify push"                BLOCK
assert_verdict "behind a wrapper"              "rtk git push"                        BLOCK
assert_verdict "behind an env assignment"      "git_ssh_command=x git push"          BLOCK
assert_verdict "after a chain operator"        "cd /tmp && git push"                 BLOCK
assert_verdict "on a later line"               "cd /tmp\ngit push"                   BLOCK
# The near-misses. The first two were BLOCKED by the hand-rolled anchor this replaces.
assert_verdict "a subcommand is not an option" "git stash push"                      silent
assert_verdict "the words inside a message"    'git commit -m \"fix git push here\"' silent
assert_verdict "a different command"           "echo push"                           silent
assert_verdict "the word inside a path"        "cat /etc/git/push.conf"              silent
assert_verdict "a longer command word"         "gitk push"                           silent
assert_verdict "a longer final word"           "git pushall"                         silent

echo ""
echo "=== @invocation-quoted-arg — command-with-quoted-argument, both directions ==="
assert_verdict "a single-quoted argument"      "supertool 'gh-pr:1' | head"          REMIND
assert_verdict "a double-quoted argument"      'supertool \"read:x\"'                REMIND
assert_verdict "an option before the quote"    "supertool -q 'read:x'"               REMIND
assert_verdict "no argument at all"            "supertool | tail"                    silent
assert_verdict "an unquoted argument"          "supertool ops"                       silent
assert_verdict "the name inside a path"        "cat /opt/supertool 'x'"              silent

echo ""
echo "=== a macro nobody defined is refused at build time and named ==="
write_entry tools/00-manual/bogus.md \
  "title: Bogus" "tool: Bash" "match: ~@invokation git push" "mode: block"
BUILD_ERR="$(rebuild 2>&1 >/dev/null)"
assert_contains "rebuild names the unknown macro" "$BUILD_ERR" "@invokation"
assert_contains "rebuild names the entry"         "$BUILD_ERR" "bogus.md"

# The row is written through UNEXPANDED on purpose: the hook then refuses it by name
# rather than compiling `@invokation git push` as a literal regex that matches nothing.
# A silently dead rule is this repo's own defect class.
echo ""
echo "=== an unexpanded macro reaching an index is refused by the hook, not ignored ==="
# On a call that is NOT blocked: the hook suppresses the refusal notice while it is
# rejecting a call, so asking for both on one command asks for something the hook has
# deliberately decided not to do.
OUT="$(drive "echo hello")"
assert_contains "the hook says the row did not run" "$OUT" "could not be evaluated"
assert_contains "and names the entry"               "$OUT" "bogus.md"
# And the honoured rule beside it is untouched — one bad row must not silence the file.
assert_contains "the honoured rule still fires" "$(drive "git push")" '"decision":"block"'

echo ""
echo "=== the macros are command shapes, so a paths entry is refused ==="
write_entry paths/00-manual/wrong.md "title: Wrong dimension" "match: @invocation git push"
PATH_ERR="$(rebuild 2>&1 >/dev/null)"
assert_contains "rebuild refuses a macro in paths" "$PATH_ERR" "wrong.md"
rm -f "$BASE/paths/00-manual/wrong.md" "$BASE/tools/00-manual/bogus.md"
rebuild >/dev/null 2>&1

echo ""
echo "=== an index that no longer matches its frontmatter is named by the dry-run ==="
CLEAN_OUT="$( (cd "$ROOT" && bash "$DRYRUN" --base "$BASE") 2>&1 )"
CLEAN_RC=$?
assert_not_contains "a freshly rebuilt tree is clean" "$CLEAN_OUT" "STALE"
if [ "$CLEAN_RC" -eq 0 ]; then ok "a freshly rebuilt tree exits 0"; else bad "a freshly rebuilt tree exits 0" "exit $CLEAN_RC"; fi

# Edit the frontmatter and do NOT rebuild — the trap this whole repo is shaped around,
# and one the macro makes harder to see by eye, because the index no longer carries the
# text the author wrote.
write_entry tools/00-manual/git-push.md \
  "title: Open a merge request instead" \
  "tool: Bash" \
  "match: ~@invocation git tag" \
  "mode: block"
STALE_OUT="$( (cd "$ROOT" && bash "$DRYRUN" --base "$BASE") 2>&1 )"
STALE_RC=$?
# One assertion, on the STALE line itself: git-push.md also appears on the `ok` line
# above it, so a bare name grep would pass on a tree the lint had nothing to say about.
assert_contains "the dry-run names the stale entry" \
  "$(printf '%s' "$STALE_OUT" | grep STALE || true)" "git-push.md"
if [ "$STALE_RC" -ne 0 ]; then ok "a stale tree exits non-zero"; else bad "a stale tree exits non-zero" "exit 0"; fi

# `match` is not the only column an index row carries. A rule silently downgraded from
# block to remind, or retargeted at another tool, is the same defect in different clothes
# -- and unlike a changed pattern it is invisible in the injected context too.
rebuild >/dev/null 2>&1
stale_after() {
  # $1 description, $2.. the frontmatter of git-push.md as it is now written
  local desc="$1" out
  shift
  write_entry tools/00-manual/git-push.md "$@"
  out="$( (cd "$ROOT" && bash "$DRYRUN" --base "$BASE") 2>&1 )"
  assert_contains "$desc" "$(printf '%s' "$out" | grep STALE || true)" "git-push.md"
  rebuild >/dev/null 2>&1
}
stale_after "a downgraded mode is stale"    "title: T" "tool: Bash" "match: ~@invocation git tag" "mode: remind"
stale_after "a retargeted tool is stale"    "title: T" "tool: Edit" "match: ~@invocation git tag" "mode: block"
stale_after "a dropped require is stale"    "title: T" "tool: Bash" "match: ~@invocation git tag" "mode: block" "require: --dry-run"
stale_after "an added forbid is stale"      "title: T" "tool: Bash" "match: ~@invocation git tag" "mode: block" "forbid: --force"

write_entry tools/00-manual/git-push.md \
  "title: Open a merge request instead" \
  "tool: Bash" \
  "match: ~@invocation git tag" \
  "mode: block"
STALE_OUT="$( (cd "$ROOT" && bash "$DRYRUN" --base "$BASE") 2>&1 )"
STALE_RC=$?
# One assertion, on the STALE line itself: git-push.md also appears on the `ok` line
# above it, so a bare name grep would pass on a tree the lint had nothing to say about.
assert_contains "the dry-run names the stale entry" \
  "$(printf '%s' "$STALE_OUT" | grep STALE || true)" "git-push.md"
if [ "$STALE_RC" -ne 0 ]; then ok "a stale tree exits non-zero"; else bad "a stale tree exits non-zero" "exit 0"; fi

rm -rf "$ROOT"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
