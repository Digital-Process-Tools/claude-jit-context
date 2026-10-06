#!/bin/bash
# #437: a slim `release` branch for the Anthropic plugin directory, ported from
# claude-remember's #851 (docs/releasing.md, "Reusing this in another plugin
# repository"). This is the local regression guard for the three ported scripts
# under .github/scripts/ and this repository's own .github/release-branch.json --
# the GitHub Actions workflow (.github/workflows/release-branch.yml) runs the same
# three scripts for real, against a pushed tag, with a pinned `claude` CLI; this
# suite runs them against the current commit so a break is caught before a tag
# is ever cut.
#
# Usage: bash tests/test-release-branch-437.sh
#
# jit-drive: none -- this drives the release-tree scripts themselves, not a hook.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/.github/scripts/build_release_tree.py"
CHECK="$REPO/.github/scripts/check_release_tree.py"
SMOKE="$REPO/.github/scripts/smoke_release_tree.py"
CONFIG="$REPO/.github/release-branch.json"

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

# classify_check_result RC OUTPUT -- "clean", "crash" or "offenders". A non-zero
# RC with no "^FAIL " line anywhere in OUTPUT is check_release_tree.py crashing
# (a traceback, not a reported offender) -- #476. Shared by this file's real
# check below and by its own self-test, so the self-test exercises the exact
# function the real flow uses rather than a restatement of it. Mirrors the
# same function in test-release-branch-461.sh.
classify_check_result() {
  local rc="$1" out="$2" fails
  if [ "$rc" -eq 0 ]; then
    echo "clean"
    return
  fi
  fails=$(printf '%s\n' "$out" | grep '^FAIL ' || true)
  if [ -z "$fails" ]; then
    echo "crash"
  else
    echo "offenders"
  fi
}

echo "=== DETECTOR SELF-TEST: classify_check_result (#476) ==="
RESULT=$(classify_check_result 0 "")
[ "$RESULT" = "clean" ] \
  && ok "classify_check_result: rc=0 -> clean" \
  || bad "classify_check_result: rc=0 should be clean, got '$RESULT'"

CRASH_OUT='Traceback (most recent call last):
  File "check_release_tree.py", line 42, in <module>
    raise ZeroDivisionError
ZeroDivisionError'
RESULT=$(classify_check_result 1 "$CRASH_OUT")
[ "$RESULT" = "crash" ] \
  && ok "classify_check_result: rc!=0, no FAIL lines -> crash (#476 -- this used to read as clean)" \
  || bad "classify_check_result: rc!=0 with no FAIL lines should be crash, got '$RESULT'"

RESULT=$(classify_check_result 1 "FAIL something.md: offender")
[ "$RESULT" = "offenders" ] \
  && ok "classify_check_result: rc!=0, FAIL line(s) present -> offenders" \
  || bad "classify_check_result: rc!=0 with a FAIL line should be offenders, got '$RESULT'"

echo "=== harness guard: the three scripts and the config exist here ==="
for f in "$BUILD" "$CHECK" "$SMOKE" "$CONFIG"; do
  [ -f "$f" ] || {
    echo "FAIL: harness guard -- $f does not exist, every assertion below is vacuous"
    exit 1
  }
done
if ! command -v python3 > /dev/null 2>&1; then
  echo "SKIPPED: no python3 on PATH -- these scripts are not part of the hook runtime"
  exit 0
fi
ok "build_release_tree.py, check_release_tree.py, smoke_release_tree.py and release-branch.json are all present"

TMPD=$(mktemp -d 2> /dev/null || mktemp -d -t jitrelease)
trap 'rm -rf "$TMPD"' EXIT
TREE="$TMPD/release-tree"

echo ""
echo "=== build: the current commit (HEAD) builds a release tree ==="
# HEAD, not the working tree: build_release_tree.py reads git objects only
# (git ls-tree/cat-file), by design -- it never reads an uncommitted edit, so this
# suite is only a true regression guard once the branch under test is committed.
BUILD_OUT=$(python3 "$BUILD" --repo "$REPO" --ref HEAD --out "$TREE" --config "$CONFIG" 2>&1)
BUILD_RC=$?
if [ "$BUILD_RC" -eq 0 ]; then
  ok "build_release_tree.py exits 0"
else
  bad "build_release_tree.py exited $BUILD_RC" "$BUILD_OUT"
fi

echo ""
echo "=== POSITIVE CONTROL: a denied path is actually gone, a shipped one actually isn't ==="
if [ -e "$TREE/tests" ]; then
  bad "tests/ (denied) is present in the built tree -- the deny-list is not being applied"
else
  ok "tests/ (denied) is absent from the built tree"
fi
if [ -e "$TREE/.github" ]; then
  bad ".github/ (denied) is present in the built tree"
else
  ok ".github/ (denied) is absent from the built tree"
fi
for shipped in scripts/pre-tool-hook.sh hooks/hooks.json .claude-plugin/plugin.json README.md LICENSE; do
  if [ -f "$TREE/$shipped" ]; then
    ok "$shipped (shipped) is present in the built tree"
  else
    bad "$shipped (shipped) is MISSING from the built tree"
  fi
done

# #461: common.sh/common-awk.sh/host.sh are compiled INTO every script that used to
# source them -- nothing loads them by path any more, so the deny-list drops them.
# Their absence here is the point, not an oversight; see compile_scripts.py.
for dropped in scripts/common.sh scripts/common-awk.sh scripts/host.sh; do
  if [ -e "$TREE/$dropped" ]; then
    bad "$dropped (library, #461) is present in the built tree -- nothing should load it by path any more"
  else
    ok "$dropped (library, #461) is correctly absent from the built tree"
  fi
done

echo ""
echo "=== #459: the README logo image is rewritten off raw.githubusercontent.com ==="
# The directory validator holds MCP_FORWARDS_CREDENTIAL_ENV on a README that spells
# the host raw.githubusercontent.com (it used to, for every markdown image). The
# rewrite now stays on the same github.com host every other link uses, with a
# ?raw=true suffix for the raw bytes.
if [ "$BUILD_RC" -eq 0 ] && [ -f "$TREE/README.md" ]; then
  if grep -q 'raw\.githubusercontent\.com' "$TREE/README.md"; then
    bad "the built README.md still spells raw.githubusercontent.com"
  else
    ok "the built README.md does not spell raw.githubusercontent.com"
  fi
  # #461: README.release.md ships as README.md and carries no image at all (no
  # $VARIABLE anywhere, by its own rule) -- the one image this build used to rewrite
  # (the logo, docs/jit-context.png) lived only in the full README.md, which no
  # longer ships. The rewrite MECHANISM is still exercised directly below
  # (_absolute(), no README involved); this is an end-to-end check with nothing
  # left to check end-to-end against, not a dropped assertion.
  if grep -q '\.png' "$TREE/README.md" 2> /dev/null; then
    if grep -qE 'https://github\.com/[^)]+\.png\?raw=true' "$TREE/README.md"; then
      ok "the logo image rewrites to a github.com blob URL with ?raw=true"
    else
      bad "a .png reference exists in the built README.md but did not rewrite to the expected github.com ...png?raw=true form" \
        "$(grep -n '\.png' "$TREE/README.md" || true)"
    fi
  else
    ok "the built README.md (README.release.md, #461) carries no image to rewrite -- the mechanism is checked directly below instead"
  fi
else
  bad "README.md rewrite check skipped -- the build above did not produce a tree"
fi

echo ""
echo "=== #459: an image link that already carries a query string does not double its '?' ==="
# Self-review on #459 found that appending our own "?raw=true" and then the
# original target's own frag (which can itself start with "?") produced a
# malformed "...?raw=true?v=2" URL -- a regression this fix itself introduced,
# since the host it replaced (raw.githubusercontent.com) never had query
# parameters of its own for frag to collide with.
if command -v python3 > /dev/null 2>&1; then
  RAWURL_OUT=$(python3 -c "
import sys
sys.path.insert(0, '$REPO/.github/scripts')
import build_release_tree as b
print(b._absolute('diagram.png?v=2', '', lambda r: 'blob', 'acme/repo', 'main'))
print(b._absolute('diagram.png?v=2#anchor', '', lambda r: 'blob', 'acme/repo', 'main'))
print(b._absolute('diagram.png#anchor', '', lambda r: 'blob', 'acme/repo', 'main'))
" 2>&1)
  if grep -q 'raw=true?' <<< "$RAWURL_OUT"; then
    bad "an image link with its own query string produced a malformed double '?' URL" "$RAWURL_OUT"
  else
    ok "an image link with its own query string (and/or anchor) merges raw=true cleanly"
  fi
fi

echo ""
echo "=== #437: every generic-word chunk in the built tree is under 256 KiB ==="
if [ -d "$TREE/data/generic-words" ]; then
  CHUNK_N=0
  OVER=""
  for chunk in "$TREE"/data/generic-words/*.txt; do
    [ -f "$chunk" ] || continue
    CHUNK_N=$((CHUNK_N + 1))
    BYTES=$(wc -c < "$chunk" | tr -d '[:space:]')
    [ "$BYTES" -lt 262144 ] || OVER="$OVER $chunk($BYTES)"
  done
  if [ "$CHUNK_N" -eq 0 ]; then
    bad "data/generic-words/ has no *.txt chunk in the built tree"
  elif [ -n "$OVER" ]; then
    bad "chunk(s) at or over 256 KiB:" "$OVER"
  else
    ok "$CHUNK_N generic-word chunk(s), all under 256 KiB"
  fi
else
  bad "data/generic-words/ is missing from the built tree -- rebuild-tsv.sh and jit-misses.sh need it on a user's machine"
fi

echo ""
echo "=== check: the built tree passes the directory's own pre-submission rules ==="
# #437 shipped with one known, pre-existing exception here: commands/doctor.md,
# commands/init.md and commands/stats.md all carried `allowed-tools: Bash` (unscoped),
# which check_release_tree.py's ALLOWED_TOOLS_BROAD rule (ported from claude-remember's
# #859) holds as a Policy hold rather than a block. #439 narrowed all three grants to
# name their own script (`Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/X.sh:*)`), moving the
# #405 zsh-safe splitting into each script itself behind a synthetic
# `--arguments-string` flag so the command body's first words could literally be the
# script invocation the grant names. The pinned offender set below is now empty: any
# allowed-tools hold that check_release_tree.py reports from here on is a genuine new
# finding, not this already-resolved one.
_KNOWN_ALLOWED_TOOLS_HOLDS=""
if [ "$BUILD_RC" -eq 0 ]; then
  CHECK_OUT=$(python3 "$CHECK" "$TREE" --config "$CONFIG" 2>&1)
  CHECK_RC=$?
  case "$(classify_check_result "$CHECK_RC" "$CHECK_OUT")" in
    clean)
      ok "check_release_tree.py exits 0"
      ;;
    crash)
      # #476: rc != 0 with no "^FAIL " line at all is check_release_tree.py
      # crashing (a traceback), not a reported offender -- the old
      # UNEXPECTED-emptiness-only check took the "known holds" ok branch here
      # too, so a crash read as a clean pass.
      bad "check_release_tree.py exited $CHECK_RC with no FAIL lines -- it crashed rather than finishing the check" "$CHECK_OUT"
      ;;
    offenders)
      UNEXPECTED=$(printf '%s\n' "$CHECK_OUT" | grep '^FAIL ' | sed 's/^FAIL //' \
        | grep -vFxf <(printf '%s\n' "$_KNOWN_ALLOWED_TOOLS_HOLDS") || true)
      if [ -z "$UNEXPECTED" ]; then
        ok "check_release_tree.py's only offender(s) are the known, already-filed ALLOWED_TOOLS_BROAD hold on commands/doctor.md, commands/init.md and commands/stats.md"
      else
        bad "check_release_tree.py reported (an) UNEXPECTED offender(s)" "$UNEXPECTED"
      fi
      ;;
  esac
else
  bad "check skipped -- the build above did not produce a tree"
fi

echo ""
echo "=== smoke: every hook in the built tree's hooks/hooks.json exits 0 ==="
# smoke_release_tree.py runs each hook command through /bin/sh, as the release workflow
# does on ubuntu-latest. A native Windows python3 has no /bin/sh (WinError 2 on every
# hook), so on such a host nothing about the hooks can be measured here: report SKIPPED
# and exit 2 rather than count six failures the release run would never see, and never
# pass it as a clean run either.
SMOKE_SKIPPED=0
if ! python3 -c 'import os, sys; sys.exit(0 if os.path.exists("/bin/sh") else 1)' 2> /dev/null; then
  SMOKE_SKIPPED=1
  echo "  SKIPPED: this python3 cannot see /bin/sh, so smoke_release_tree.py cannot start a hook here -- the release workflow runs it on ubuntu-latest"
elif [ "$BUILD_RC" -eq 0 ]; then
  SMOKE_OUT=$(python3 "$SMOKE" "$TREE" --validate auto 2>&1)
  SMOKE_RC=$?
  if [ "$SMOKE_RC" -eq 0 ]; then
    ok "smoke_release_tree.py exits 0 (every hook ran and exited 0)"
  else
    bad "smoke_release_tree.py exited $SMOKE_RC" "$SMOKE_OUT"
  fi
  HOOK_N=$(printf '%s\n' "$SMOKE_OUT" | grep -cE '^(PASS|FAIL) ')
  if [ "$HOOK_N" -eq 6 ]; then
    ok "all 6 commands in hooks/hooks.json were exercised"
  else
    bad "expected 6 hook command(s) exercised, counted $HOOK_N" "$SMOKE_OUT"
  fi
else
  bad "smoke skipped -- the build above did not produce a tree"
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
[ "$SMOKE_SKIPPED" -eq 0 ] || exit 2
exit 0
