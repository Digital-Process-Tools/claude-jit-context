#!/usr/bin/env bash
# Every tool and hook under scripts/ is executable; the sourced libraries are not.
#
# Measured on cfd0621, the squash of #324: 45 of the 81 tracked shell files carry the
# bit, and under scripts/ the split is exact -- every entry point is 100755 and the two
# sourced libraries are 100644. That merge dropped the bit on jit-dry-run.sh, which is
# an entry point, and nothing anywhere failed: every caller in this tree runs it as
# `bash "$DRYRUN"`, so the mode is documentation of how a file is meant to be reached
# rather than something a caller trips over. Documentation nothing checks is the thing
# this repository is about.
#
# tests/ is deliberately NOT swept. There is no convention there to enforce -- 36 of the
# 45 files are 100644 and the rest are not, so a rule either way would fail most of the
# directory or assert whatever the last commit happened to leave behind.
#
# jit-drive: none -- every assertion here reads the git index directly and takes no hook output

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR" || { echo "SKIPPED: cannot reach the repository root"; exit 2; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1: $2"; }

# Sourced by other scripts, never invoked. Executable would be a lie about how they run.
is_library() {
  case "$1" in
    scripts/common.sh | scripts/host.sh) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== the harness can see this tree's own scripts ==="

MODES="$(git ls-files -s 'scripts/*.sh' 2>/dev/null)"
COUNT="$(printf '%s\n' "$MODES" | grep -c 'scripts/' || true)"
if [ "${COUNT:-0}" -lt 5 ]; then
  echo "SKIPPED: git ls-files returned $COUNT tracked scripts/*.sh -- every assertion below"
  echo "         would be vacuously true, so none of them ran."
  exit 2
fi
pass "git ls-files reports $COUNT tracked scripts/*.sh"

# The positive control for the allowlist. Both libraries carry a shebang -- that is a
# a lint convention here, not evidence of how they run -- so the property that earns
# the exemption is that something sources them and nothing invokes them. If a library
# ever becomes an entry point, this goes red before the sweep below exempts it wrongly.
echo "=== each allowlisted library is sourced, not invoked ==="

for lib in scripts/common.sh scripts/host.sh; do
  if [ ! -f "$lib" ]; then
    fail "$lib is a real file" "not found -- the allowlist names something that is gone"
    continue
  fi

  base="${lib#scripts/}"
  sourced="$(grep -lE "^[[:space:]]*(\\.|source)[[:space:]]+.*${base}" scripts/*.sh 2>/dev/null | grep -cv "^${lib}$" || true)"
  if [ "${sourced:-0}" -ge 1 ]; then
    pass "$lib is sourced by $sourced script(s) under scripts/"
  else
    fail "$lib is sourced by something" "no script under scripts/ sources it -- the exemption has stopped describing it"
  fi

  # Comment lines are stripped first: two of them name common.sh in prose, and a rule that
  # reads a comment as an invocation reports a finding about the documentation.
  invoked=0
  for f in scripts/*.sh; do
    [ "$f" = "$lib" ] && continue
    body="$(grep -vE "^[[:space:]]*#" "$f" 2>/dev/null)"
    grep -qE -- "(^|[[:space:]])(bash|sh)[[:space:]]+[^|;&]*${base}" <<<"$body" \
      && invoked=$((invoked + 1))
  done
  if [ "${invoked:-0}" -eq 0 ]; then
    pass "$lib is never invoked as a command"
  else
    fail "$lib is never invoked as a command" "$invoked script(s) run it -- it is an entry point and must carry the bit"
  fi
done

echo "=== every entry point under scripts/ is executable ==="

while IFS= read -r row; do
  [ -n "$row" ] || continue
  mode="${row%% *}"
  path="${row#*$'\t'}"

  if is_library "$path"; then
    if [ "$mode" = "100644" ]; then
      pass "$path is not executable (sourced library)"
    else
      fail "$path is not executable" "mode is $mode -- a sourced library carrying the bit"
    fi
    continue
  fi

  if [ "$mode" = "100755" ]; then
    pass "$path is executable"
  else
    fail "$path is executable" "mode is $mode in the git index -- restore with: git update-index --chmod=+x $path"
  fi
done <<< "$MODES"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
