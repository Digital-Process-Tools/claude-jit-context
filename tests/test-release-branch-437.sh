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
for shipped in scripts/common.sh hooks/hooks.json .claude-plugin/plugin.json README.md LICENSE; do
  if [ -f "$TREE/$shipped" ]; then
    ok "$shipped (shipped) is present in the built tree"
  else
    bad "$shipped (shipped) is MISSING from the built tree"
  fi
done

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
# #437: one known, pre-existing, ALREADY-FILED exception -- commands/doctor.md,
# commands/init.md and commands/stats.md all carry `allowed-tools: Bash` (unscoped),
# which check_release_tree.py's ALLOWED_TOOLS_BROAD rule (ported from claude-remember's
# #859) holds as a Policy hold rather than a block. claude-remember's own first
# release-branch cut shipped with this exact hold present on its own commands/doctor.md
# and fixed it in a LATER, dedicated PR (#859) rather than as part of porting the
# tooling -- the same precedent this suite follows. Narrowing the grant correctly needs
# verifying how Claude Code's allowed-tools pattern matches the literal `bash -c '...'`
# wrapper these three commands use for #405 (zsh's `read -a` incompatibility); getting
# that wrong would reintroduce a permission prompt on three everyday commands, which is
# a user-facing regression this port must not risk guessing at. So this assertion is
# pinned to the KNOWN offender set: new offenders still fail the suite; these three do
# not, until a follow-up issue (tracking claude-remember's own #859) resolves them.
_KNOWN_ALLOWED_TOOLS_HOLDS="commands/doctor.md: allowed-tools grants unrestricted shell ('Bash'): bare \`Bash\` grants every shell command
commands/init.md: allowed-tools grants unrestricted shell ('Bash'): bare \`Bash\` grants every shell command
commands/stats.md: allowed-tools grants unrestricted shell ('Bash'): bare \`Bash\` grants every shell command"
if [ "$BUILD_RC" -eq 0 ]; then
  CHECK_OUT=$(python3 "$CHECK" "$TREE" --config "$CONFIG" 2>&1)
  CHECK_RC=$?
  if [ "$CHECK_RC" -eq 0 ]; then
    ok "check_release_tree.py exits 0"
  else
    UNEXPECTED=$(printf '%s\n' "$CHECK_OUT" | grep '^FAIL ' | sed 's/^FAIL //' \
      | grep -vFxf <(printf '%s\n' "$_KNOWN_ALLOWED_TOOLS_HOLDS") || true)
    if [ -z "$UNEXPECTED" ]; then
      ok "check_release_tree.py's only offender(s) are the known, already-filed ALLOWED_TOOLS_BROAD hold on commands/doctor.md, commands/init.md and commands/stats.md"
    else
      bad "check_release_tree.py reported (an) UNEXPECTED offender(s)" "$UNEXPECTED"
    fi
  fi
else
  bad "check skipped -- the build above did not produce a tree"
fi

echo ""
echo "=== smoke: every hook in the built tree's hooks/hooks.json exits 0 ==="
if [ "$BUILD_RC" -eq 0 ]; then
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
[ "$FAIL" -eq 0 ]
