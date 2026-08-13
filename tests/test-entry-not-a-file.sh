#!/bin/bash
# Tests for #97 and #98 — an index row whose entry path is not a regular file.
# Usage: bash tests/test-entry-not-a-file.sh
#
# #97. Every entry read concatenates a layer directory with the index file-name column and
# getlines the result -- five sites in the three hooks, plus jit-dry-run.sh. awk cannot
# stat, so nothing established that the result is a regular file. On one-true-awk — the awk macOS ships — getline on a
# DIRECTORY is a fatal i/o error raised inside END: the process dies, stdout carries no
# JSON at all, and a `block` decision already reached is destroyed with it. Driven at
# f63555e: awk version 20200816 died, GNU Awk 5.4.1 blocked correctly. That split is why
# every assertion here runs once per awk on this machine, through the PATH shim the other
# suites use — a test that only ran under gawk would prove nothing about this bug.
#
# Two shapes reach the same getline, and both are committable:
#   a file column naming a directory, `dirent.md/` with a file inside;
#   an EMPTY file column, which concatenates to the layer directory itself. That column is
#   deliberately allowed through jit_bad_entry_file() as "a blank index line".
#
# The assertion that matters is not that the bad row is refused. It is that a `block` rule
# AFTER the bad row still blocks — the decision survives the row that cannot be read, which
# is what pre-tool-hook.sh has claimed in a comment since #77 and did not do here.
#
# #98. jit-dry-run.sh wrapped that same read in 2>/dev/null, so the fatal read as an empty
# result set — which reads as a pass — and awk aborting at the record dropped every row
# after it. Three states, not two: ok, a finding, and skipped.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

WORK=$(mktemp -d)
ERRFILE="$WORK/stderr.txt"
trap 'rm -rf "$WORK"' EXIT

# --- Helpers ---
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -q -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:300}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -q -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:300}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_equals() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected: $want"
    echo "    got:      $got"
  fi
}

# The hook contract is that it says nothing INTO THE SESSION when it cannot evaluate
# something. A fatal awk diagnostic on stderr is the visible half of #97 and the half a
# user reports; the destroyed decision is the half nobody sees.
assert_silent_stderr() {
  local desc="$1"
  if [ -s "$ERRFILE" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    stderr carried: $(head -c 300 "$ERRFILE")"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}
# --- The awk engine matrix ---
# Same shim as tests/test-pre-tool-hook.sh. One directory per engine holding an `awk`
# that execs it, prepended to PATH, so the hook resolves the engine under test without
# knowing it is under test.
ENGINE_BIN="$WORK/enginebin"
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2>/dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

if [ -z "$ENGINES" ]; then
  echo "SKIPPED: no awk on PATH. The matcher itself is missing, so nothing here was checked."
  exit 2
fi

# --- Fixtures ---
# Every tree carries the bad row FIRST and honest rules after it, in all three dimensions.
# A bad row at the end would pass under the unfixed code by accident: one-true-awk aborts
# AT the record, so everything before it has already been emitted.
mk_tree() {
  # $1 project root, $2 shape: dir | empty
  local root="$1" shape="$2" t p v
  t="$root/.claude/jit-context/tools/00-manual"
  p="$root/.claude/jit-context/paths/00-manual"
  v="$root/.claude/jit-context/vocabulary/00-manual"
  mkdir -p "$t" "$p" "$v"
  if [ "$shape" = dir ]; then
    mkdir -p "$t/dirent.md" "$p/dirent.md" "$v/dirent.md"
    # git commits a directory that has a file in it, so this shape arrives with a clone.
    echo "PLANTED-BODY-MUST-NOT-BE-INJECTED" > "$t/dirent.md/inner.txt"
    echo "PLANTED-BODY-MUST-NOT-BE-INJECTED" > "$p/dirent.md/inner.txt"
    echo "PLANTED-BODY-MUST-NOT-BE-INJECTED" > "$v/dirent.md/inner.txt"
    printf '%s\t%s\t%s\t%s\t\t\n' Bash 'git ' dirent.md remind > "$t/00-index.tsv"
    printf '%s\t%s\n' '\.php' dirent.md > "$p/00-index.tsv"
    printf '%s\t%s\n' billing dirent.md > "$v/00-index.tsv"
  elif [ "$shape" = empty ]; then
    printf '%s\t%s\t%s\t%s\t\t\n' Bash 'git ' '' remind > "$t/00-index.tsv"
    printf '%s\t%s\n' '\.php' '' > "$p/00-index.tsv"
    printf '%s\t%s\n' billing '' > "$v/00-index.tsv"
  else
    # shape `clean`: the same tree with no unreadable row in it at all. The control for
    # every assertion below, and the fixture the aborting-reader leg needs — on a tree
    # whose only fault is that the reader died, an assertion that passes on a dirty tree
    # would be passing for the wrong reason.
    : > "$t/00-index.tsv"
    : > "$p/00-index.tsv"
    : > "$v/00-index.tsv"
  fi
  # The rows that must survive the one above.
  printf '%s\t%s\t%s\t%s\t\t\n' Bash 'git push' block.md block >> "$t/00-index.tsv"
  printf '%s\t%s\t%s\t%s\t\t\n' Bash 'git status' status.md remind >> "$t/00-index.tsv"
  echo "do not push to main" > "$t/block.md"
  echo "status rule context" > "$t/status.md"
  printf '%s\t%s\n' 'src/' client.md >> "$p/00-index.tsv"
  echo "client rule context" > "$p/client.md"
  printf '%s\t%s\n' payments payments.md >> "$v/00-index.tsv"
  echo "payments vocabulary context" > "$v/payments.md"
}

run_hook() {
  # $1 engine, $2 hook script, $3 payload, $4 project root
  : > "$ERRFILE"
  printf '%s' "$3" | PATH="$ENGINE_BIN/$1:$PATH" CLAUDE_PROJECT_DIR="$4" bash "$SCRIPT_DIR/scripts/$2" 2>"$ERRFILE"
}
# =============================================
# SECTION 1 (#97): the hooks, once per engine, both bad shapes
# =============================================
for eng in $ENGINES; do
  for shape in dir empty; do
    ROOT="$WORK/h-$eng-$shape"
    mk_tree "$ROOT" "$shape"

    echo ""
    echo "=== [$eng] tools: entry path is $shape ==="
    OUT=$(run_hook "$eng" pre-tool-hook.sh '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$ROOT")
    # THE assertion. The bad row is row 1 and the block rule is row 2, so a reader that
    # dies at row 1 takes the refusal with it and the call runs.
    assert_contains "a block rule AFTER the unreadable row still blocks" "$OUT" '"decision":"block"'
    assert_silent_stderr "nothing reaches the session on stderr"
    assert_not_contains "the planted directory content is never injected" "$OUT" "PLANTED-BODY"

    OUT=$(run_hook "$eng" pre-tool-hook.sh '{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"git status"}}' "$ROOT")
    assert_contains "an honest remind rule after it still fires" "$OUT" "status rule context"
    assert_silent_stderr "nothing on stderr for the remind path either"

    OUT=$(run_hook "$eng" pre-tool-hook.sh '{"session_id":"s3","tool_name":"Bash","tool_input":{"command":"git log --oneline"}}' "$ROOT")
    assert_contains "the row itself is named as unevaluated, not silently skipped" "$OUT" "could not be evaluated"

    # Must-not-fire, in the same fixture. A hook that answered {} to everything would
    # satisfy the negative alone.
    OUT=$(run_hook "$eng" pre-tool-hook.sh '{"session_id":"s4","tool_name":"Bash","tool_input":{"command":"svn commit -m x"}}' "$ROOT")
    assert_equals "a command no row matches is still silent" "$OUT" "{}"

    echo ""
    echo "=== [$eng] paths: entry path is $shape ==="
    # src/x.php matches BOTH rows: the unreadable one and the honest one after it.
    OUT=$(run_hook "$eng" pre-path-hook.sh "{\"session_id\":\"s5\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$ROOT/src/x.php\"}}" "$ROOT")
    assert_contains "the honest paths rule after it still fires" "$OUT" "client rule context"
    assert_contains "the unreadable paths row is named" "$OUT" "could not be evaluated"
    assert_silent_stderr "nothing on stderr from the path hook"
    assert_not_contains "the planted directory content is never injected" "$OUT" "PLANTED-BODY"

    OUT=$(run_hook "$eng" pre-path-hook.sh "{\"session_id\":\"s6\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$ROOT/docs/x.md\"}}" "$ROOT")
    assert_equals "a path no row matches is still silent" "$OUT" "{}"

    echo ""
    echo "=== [$eng] vocabulary: entry path is $shape ==="
    OUT=$(run_hook "$eng" pre-prompt-hook.sh '{"session_id":"s7","prompt":"how does billing reach payments"}' "$ROOT")
    assert_contains "the vocabulary entry after it still fires" "$OUT" "payments vocabulary context"
    assert_silent_stderr "nothing on stderr from the prompt hook"
    assert_not_contains "the planted directory content is never injected" "$OUT" "PLANTED-BODY"

    OUT=$(run_hook "$eng" pre-prompt-hook.sh '{"session_id":"s8","prompt":"nothing here matches any keyword"}' "$ROOT")
    assert_equals "a prompt no keyword matches is still silent" "$OUT" "{}"
  done

  echo ""
  echo "=== [$eng] control: the same tree with no unreadable row ==="
  CLEAN="$WORK/h-$eng-clean"
  mk_tree "$CLEAN" clean
  OUT=$(run_hook "$eng" pre-tool-hook.sh '{"session_id":"s9","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$CLEAN")
  assert_contains "still blocks" "$OUT" '"decision":"block"'
  assert_not_contains "and refuses nothing" "$OUT" "could not be evaluated"
done
# =============================================
# SECTION 2 (#98): jit-dry-run.sh over the tree that kills the hook
# =============================================
# The linter is what the injected refusal notice tells the reader to run, and CI consumes
# its exit code (#47). A tree it cannot honour must not exit 0.
for eng in $ENGINES; do
  echo ""
  echo "=== [$eng] jit-dry-run: the tree that kills the hook is not a clean tree ==="
  DRY="$WORK/d-$eng"
  mk_tree "$DRY" dir
  DTOOLS="$DRY/.claude/jit-context/tools/00-manual"
  # A row the linter ALREADY knew how to name, placed after the unreadable one. Under the
  # fatal it vanished with every other row and the run printed "0 refused" — that is the
  # dropped-rows half of #98, and it is why this row is here rather than alone.
  printf 'Bash\t%b\tbadbyte.md\tremind\t\t\n' 'caf\xe9' >> "$DTOOLS/00-index.tsv"
  echo "badbyte rule context" > "$DTOOLS/badbyte.md"

  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" \
    --base "$DRY/.claude/jit-context" --tool Bash --command "git push origin main" 2>&1)
  RC=$?
  assert_contains "the unreadable row is named" "$OUT" "not a regular file"
  assert_contains "the row AFTER it is still checked" "$OUT" "not valid UTF-8"
  assert_contains "the sample call shows the block that hook actually makes" "$OUT" "BLOCK"
  assert_not_contains "and never reports that block rule as not firing" "$OUT" "pre-tool-hook.sh   no rule fired"
  if [ "$RC" -eq 0 ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: exit is non-zero over a tree that cannot be honoured"
    echo "    got exit 0"
  else
    PASS=$((PASS + 1)); echo "  PASS: exit is non-zero over a tree that cannot be honoured"
  fi

  echo ""
  echo "=== [$eng] jit-dry-run: control — the same tree with no unreadable row ==="
  DCLEAN="$WORK/dc-$eng"
  mk_tree "$DCLEAN" clean
  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" \
    --base "$DCLEAN/.claude/jit-context" --tool Bash --command "git push origin main" 2>&1)
  RC=$?
  assert_equals "a clean tree still exits 0" "$RC" "0"
  assert_contains "and the block still shows" "$OUT" "BLOCK"
  assert_not_contains "with nothing refused" "$OUT" "REFUSED"
done

# =============================================
# SECTION 3 (#97): the wider net — a FIFO at an entry path
# =============================================
# The guard asks "is this a regular file", not "is this a directory", and four places in
# the prose say so. A FIFO is the shape that makes the wider question worth asking: reading
# one does not abort the hook, it BLOCKS it, forever, in a process contracted to answer
# inside 110 ms.
#
# ASSERTED ON THE SET, not on a hook run, and that is deliberate. Driving the read
# end-to-end would prove more — and if the guard ever regressed, the suite would HANG
# instead of failing, on CI, with no output naming the leg. A test whose failure mode is a
# timeout is a test nobody reads. So this asserts the one thing the directory legs above
# cannot: that `[ -e ]` records a non-directory non-file too, which is the branch every
# claim about FIFOs rests on.
if command -v mkfifo >/dev/null 2>&1; then
  FIFOROOT="$WORK/fifo"
  mk_tree "$FIFOROOT" clean
  FT="$FIFOROOT/.claude/jit-context/tools/00-manual"
  if mkfifo "$FT/pipe.md" 2>/dev/null && [ -p "$FT/pipe.md" ]; then
    echo ""
    echo "=== the sweep records a FIFO at an entry path, not only a directory ==="
    NF=$(CLAUDE_PROJECT_DIR="$FIFOROOT" bash -c '. "$0"/scripts/common.sh; printf "%s" "$JIT_NONFILES"' "$SCRIPT_DIR")
    assert_contains "a FIFO at entry depth is in the non-file set" "$NF" "pipe.md"
    # The control, and it is the assertion that stops the one above passing on a set that
    # simply lists everything: the honest entry file beside it must NOT be in there.
    assert_not_contains "and an ordinary entry file beside it is not" "$NF" "block.md"
  else
    echo ""
    echo "SKIPPED: mkfifo did not produce a FIFO here, so the wider-net leg went untested."
  fi
else
  echo ""
  echo "SKIPPED: no mkfifo on this platform, so the wider-net leg went untested."
fi

echo ""
echo "=== jit-dry-run: a reader that aborts is a third state, never a pass ==="
# 2>/dev/null on the row-bytes awk turned a FATAL into an empty result set, and an empty
# result set reads as a clean tree. The fatal itself is now guarded against, so it is
# produced here on purpose: an awk that refuses the tools index and nothing else. The tree
# under it is CLEAN, so a run that reports nothing is reporting the abort as a pass.
REAL_AWK=$(command -v awk)
ABORT_BIN="$WORK/abortbin"
mkdir -p "$ABORT_BIN"
{
  echo '#!/bin/sh'
  echo 'for a in "$@"; do'
  echo '  case "$a" in */tools/00-manual/00-index.tsv) exit 2 ;; esac'
  echo 'done'
  printf 'exec %s "$@"\n' "$REAL_AWK"
} > "$ABORT_BIN/awk"
chmod +x "$ABORT_BIN/awk"

ACLEAN="$WORK/abort-tree"
mk_tree "$ACLEAN" clean
OUT=$(PATH="$ABORT_BIN:$PATH" bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" \
  --base "$ACLEAN/.claude/jit-context" 2>&1)
RC=$?
# The layer has to be ON the SKIPPED line. "tools/00-manual" appears elsewhere in every
# report, so an unanchored assertion here would pass over a run that said nothing.
assert_contains "the index the reader could not finish is reported as skipped, by name" "$OUT" "SKIPPED  tools/00-manual"
if [ "$RC" -eq 0 ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: exit is non-zero when a row reader aborted"
  echo "    got exit 0 — CI consumes this code (#47)"
else
  PASS=$((PASS + 1)); echo "  PASS: exit is non-zero when a row reader aborted"
fi

# The control for the leg above: the same clean tree, without the aborting awk.
OUT=$(bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" --base "$ACLEAN/.claude/jit-context" 2>&1)
RC=$?
assert_equals "and the same tree with a working awk exits 0" "$RC" "0"
assert_not_contains "with nothing skipped" "$OUT" "SKIPPED"

echo ""
echo "=== jit-dry-run: a HOOK that writes to stderr is the same third state ==="
# The other half of the 2>/dev/null fix, one phase over. Phase 2 discarded the hook's
# stderr, so the process that died mid-decision reported as "no rule fired" — and that
# reads as a rule with nothing to say. Produced here with an awk that does its job and
# then says something: the tree is CLEAN and the rule still fires, so nothing but the
# stderr channel can be what this leg is detecting.
NOISY_BIN="$WORK/noisybin"
mkdir -p "$NOISY_BIN"
{
  echo '#!/bin/sh'
  printf '%s "$@"\n' "$REAL_AWK"
  echo 'rc=$?'
  echo 'echo "engine noise" >&2'
  echo 'exit $rc'
} > "$NOISY_BIN/awk"
chmod +x "$NOISY_BIN/awk"
OUT=$(PATH="$NOISY_BIN:$PATH" bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" \
  --base "$ACLEAN/.claude/jit-context" --tool Bash --command "git push origin main" 2>&1)
RC=$?
assert_contains "the sample call reports the hook that wrote to stderr" "$OUT" "SKIPPED pre-tool-hook.sh"
assert_contains "and still shows what it did fire, because that is not the whole answer" "$OUT" "BLOCK"
if [ "$RC" -eq 0 ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: exit is non-zero when a hook wrote to stderr"
  echo "    got exit 0"
else
  PASS=$((PASS + 1)); echo "  PASS: exit is non-zero when a hook wrote to stderr"
fi

# Control: the same clean tree and the same sample call with an ordinary awk.
OUT=$(bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" \
  --base "$ACLEAN/.claude/jit-context" --tool Bash --command "git push origin main" 2>&1)
RC=$?
assert_equals "a quiet hook on a clean tree exits 0" "$RC" "0"
assert_contains "and blocks" "$OUT" "BLOCK"
assert_not_contains "with nothing reported skipped" "$OUT" "SKIPPED"

echo ""
echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
echo "engines driven:$ENGINES"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
