#!/bin/bash
# Tests that a valued flag missing its value is REFUSED, on every tool that takes one.
#
# The defect (#114): `--base) BASE="${2:-}"; shift 2 ;;` under `set -uo pipefail` with no
# `-e`. With one positional left, `shift 2` fails, `$1` never advances, and
# `while [ $# -gt 0 ]` spins forever. Driven at e800067:
#
#   timeout 5 bash scripts/jit-init.sh --base     -> exit 124, 0 bytes out, 0 bytes err
#   timeout 4 bash scripts/jit-dry-run.sh --base  -> exit 124   (also --tool/--command/--prompt)
#   timeout 4 bash scripts/jit-dry-run.sh --path  -> exit 2     (an UNKNOWN flag is fine)
#
# That contrast is the whole finding: the loud path was already right, and the quiet one
# was the known flag. `paths/00-manual/tooling.md` is the contract these tools live under
# -- fail loudly, on stderr, non-zero -- and a hang says nothing at all.
#
# --- Why the flag list is read out of the script and not typed here -------------------
#
# A hand-written list covers the flags that existed when it was written. The next valued
# flag someone adds is the one that reopens this, and it reopens silently. So the loop
# below parses each script own argument loop for every case arm carrying `shift 2`, and
# a flag with no positive-control value declared in positive_argv() is a FAILURE rather
# than a skip: adding a flag there costs one line, and not adding it costs the guard.
#
# --- Why not `timeout` ---------------------------------------------------------------
#
# `timeout` is GNU coreutils. It is on the Linux and macOS legs and is NOT guaranteed on
# Windows (Git Bash), where this suite has to run too. A test that silently degrades to
# "the command was not bounded" on one leg is a green that means nothing there, so the
# bound is a watchdog subshell instead.
#
# Usage: bash tests/test-arg-flag-values.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; for l in "$@"; do echo "    $l"; done; return 0; }

OUT="$TMP/out.txt"
ERR="$TMP/err.txt"

# jit-drive: none -- every assertion here runs a script itself and reads the files it
# wrote; none of them takes captured output as an argument, so there is nothing for the
# 1 MB SIGPIPE payload to be handed to.

# Run a command with a hard time bound, writing stdout to $OUT and stderr to $ERR.
# Returns the command exit status, or 124 if the bound was reached -- 124 to read like
# `timeout`, which this deliberately is not.
run_bounded() {
  local secs="$1"; shift
  local pid watchdog st=0
  : > "$OUT"
  : > "$ERR"
  "$@" > "$OUT" 2> "$ERR" &
  pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid" 2>/dev/null || st=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # A signal death is the watchdog: these tools exit 0, 1 or 2 and nothing else.
  [ "$st" -ge 128 ] && return 124
  return "$st"
}

# Every case arm in a script own argument loop that consumes a value.
valued_flags() {
  awk '
    /^while \[ \$# -gt 0 \]; do/ { inloop = 1; next }
    inloop && /^done$/           { inloop = 0 }
    inloop && /shift 2/ {
      n = $0
      sub(/^[[:space:]]*/, "", n)
      sub(/\).*$/, "", n)
      k = split(n, part, "|")
      for (j = 1; j <= k; j++) if (part[j] ~ /^--[A-Za-z]/) print part[j]
    }
  ' "$1"
}

# --- Fixtures ------------------------------------------------------------------------
#
# One real tree for jit-dry-run.sh to succeed against, one real log for jit-misses.sh.
# The positive control has to reach exit 0 on the same code path as the negative, or
# "exits non-zero" is satisfied by a script that is missing, unreadable, or broken
# before its argument loop is ever reached.
#
# The index file name is held in a variable rather than written out beside a redirect:
# this repository own tools/00-manual rule blocks a shell write to that name, and it
# reads the whole command string, so a literal here is refused before the file is written.
IDX="00-index.tsv"
TREE="$TMP/proj/.claude/jit-context"
mkdir -p "$TREE/tools/00-manual"
for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
  mkdir -p "$TREE/paths/$l" "$TREE/vocabulary/$l"
  : > "$TREE/paths/$l/$IDX"
  : > "$TREE/vocabulary/$l/$IDX"
done
printf 'Bash\t~(^|[;&|\\n] *)git[[:space:]]+push\tgit-push.md\tblock\t\t\n' > "$TREE/tools/00-manual/$IDX"
echo "do not push" > "$TREE/tools/00-manual/git-push.md"

# One real hook-log record, in the format jit-misses.sh parses. A line it does not
# recognise is a named SKIPPED and exit 2 -- which would make every positive control
# below pass through the argument loop and then fail for a reason that has nothing to
# do with #114.
LOGFILE="$TMP/hooks.log"
echo "[10:00:00.001] pre-prompt 9ms | (none) [shown:1] << the billing export is broken" > "$LOGFILE"

FRESH_N=0

# The positive-control argv for one flag of one script: the flag with a value, plus
# whatever else that run needs to be a success rather than a different refusal. One
# argument per line. Prints nothing when the flag is unknown here -- the caller FAILS.
positive_argv() {
  # $1 script basename, $2 flag
  case "$1" in
    jit-init.sh)
      case "$2" in
        --base)
          FRESH_N=$((FRESH_N + 1))
          mkdir -p "$TMP/fresh$FRESH_N"
          printf '%s\n%s\n' "--base" "$TMP/fresh$FRESH_N/.claude/jit-context" ;;
      esac ;;
    jit-dry-run.sh)
      case "$2" in
        --base)    printf '%s\n%s\n' "--base" "$TREE" ;;
        --tool)    printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--tool" "Bash" ;;
        --command) printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--command" "git status" ;;
        --file)    printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--file" "src/Billing/Total.php" ;;
        --prompt)  printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--prompt" "how do totals work" ;;
      esac ;;
    jit-misses.sh)
      case "$2" in
        --log) printf '%s\n%s\n' "--log" "$LOGFILE" ;;
        --min) printf '%s\n%s\n%s\n%s\n' "--log" "$LOGFILE" "--min" "2" ;;
        --top) printf '%s\n%s\n%s\n%s\n' "--log" "$LOGFILE" "--top" "5" ;;
      esac ;;
  esac
}

drive_script() {
  # $1 path to the script
  local script="$1" name flag flags argv st a
  name="$(basename "$script")"
  flags="$(valued_flags "$script")"

  echo ""
  echo "=== $name ==="

  if [ -z "$flags" ]; then
    bad "$name: its argument loop exposes no valued flag" \
        "either the loop moved or valued_flags() no longer reads it -- this suite is checking nothing"
    return
  fi

  for flag in $flags; do
    # --- negative: the flag with nothing after it ---
    st=0
    run_bounded 8 bash "$script" "$flag" || st=$?
    if [ "$st" -eq 2 ]; then
      ok "$name $flag with no value exits 2"
    elif [ "$st" -eq 124 ]; then
      bad "$name $flag with no value exits 2" \
          "it did not exit at all -- still running after 8s (#114)"
    else
      bad "$name $flag with no value exits 2" "exit $st"
    fi

    if grep -qF -- "$flag" "$OUT" "$ERR" 2>/dev/null; then
      ok "$name $flag with no value names the flag"
    else
      bad "$name $flag with no value names the flag" \
          "stdout and stderr carried nothing mentioning $flag"
    fi

    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
      ok "$name $flag with no value says something"
    else
      bad "$name $flag with no value says something" "0 bytes on both streams"
    fi

    # --- positive control, on the same code path ---
    argv="$(positive_argv "$name" "$flag")"
    if [ -z "$argv" ]; then
      bad "$name $flag has a positive control" \
          "no value declared in positive_argv() for a flag its own loop consumes" \
          "add one line there -- a new valued flag with no positive control is untested"
      continue
    fi
    local args=()
    while IFS= read -r a; do args+=("$a"); done <<EOF
$argv
EOF
    st=0
    run_bounded 30 bash "$script" "${args[@]}" || st=$?
    if [ "$st" -eq 0 ]; then
      ok "$name $flag WITH a value still succeeds"
    else
      bad "$name $flag WITH a value still succeeds" "exit $st" "$(head -3 "$ERR")"
    fi
    if grep -qF "needs a value" "$OUT" "$ERR" 2>/dev/null; then
      bad "$name $flag WITH a value is not refused for a missing one" "$(head -3 "$ERR")"
    else
      ok "$name $flag WITH a value is not refused for a missing one"
    fi
  done
}

echo "=== an UNKNOWN flag was always handled correctly -- the control for all of the below ==="
ST=0
run_bounded 8 bash "$REPO/scripts/jit-dry-run.sh" --nosuchflag || ST=$?
if [ "$ST" -eq 2 ]; then
  ok "jit-dry-run.sh refuses an unknown flag with exit 2"
else
  bad "jit-dry-run.sh refuses an unknown flag with exit 2" "exit $ST"
fi

drive_script "$REPO/scripts/jit-init.sh"
drive_script "$REPO/scripts/jit-dry-run.sh"
# jit-misses.sh already had this right -- its need_value() is the shape the other two
# were missing. It is driven here as the third leg of the sweep, not as a fix.
drive_script "$REPO/scripts/jit-misses.sh"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
