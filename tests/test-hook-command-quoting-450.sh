#!/bin/bash
# #450: hooks/hooks.json ran `bash ${CLAUDE_PLUGIN_ROOT}/scripts/X.sh` unquoted. A plugin
# root with a space in it (a home directory with a space, for example) splits that into
# several words, `bash` is handed a path that does not exist, and the hook never runs,
# silently. `claude plugin validate --strict` warns on all six. hooks/hooks.codex.json
# already quoted its placeholder.
#
# Two legs: every command in both manifests carries its root placeholder inside double
# quotes; and every hooks.json command, run the way a shell runs it with the root set to
# a directory WITH a space, actually reaches its script and exits 0.
#
# Usage: bash tests/test-hook-command-quoting-450.sh
#
# jit-drive: all -- every hook command in hooks/hooks.json is run once, unchanged.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [ -n "${2:-}" ] && echo "    $2"
}

commands_of() {
  # One command string per line, the JSON escape for a quote undone. Read with awk, not
  # a JSON parser: this suite must run where the hooks run, with no python or jq.
  awk -F'"command": "' 'NF > 1 { s = $2; sub(/"[[:space:]]*,?[[:space:]]*$/, "", s); gsub(/\\"/, "\"", s); print s }' "$1"
}

echo "=== static: the root placeholder is inside double quotes, in both manifests ==="
for manifest in hooks/hooks.json hooks/hooks.codex.json; do
  n=0
  while IFS= read -r cmd; do
    n=$((n + 1))
    case "$cmd" in
      *'"${CLAUDE_PLUGIN_ROOT}/'* | *'"${PLUGIN_ROOT}/'*) ok "$manifest: quoted -- $cmd" ;;
      *) bad "$manifest: root placeholder not quoted" "$cmd" ;;
    esac
  done < <(commands_of "$REPO/$manifest")
  if [ "$n" -eq 6 ]; then
    ok "$manifest: 6 commands read (the sweep saw them all)"
  else
    bad "$manifest: expected 6 commands, read $n" "the static leg above may be vacuous"
  fi
done

echo ""
echo "=== dynamic: every hooks.json command runs from a plugin root with a space in it ==="
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
ROOT="$SCRATCH/plugin root with space"
mkdir -p "$ROOT" "$SCRATCH/home" "$SCRATCH/project"
cp -R "$REPO/scripts" "$REPO/hooks" "$ROOT/"
[ -d "$REPO/data" ] && cp -R "$REPO/data" "$ROOT/"
n=0
while IFS= read -r cmd; do
  n=$((n + 1))
  out=$(cd "$SCRATCH/project" && printf '{"session_id":"q450","hook_event_name":"Stop","cwd":"%s"}' "$SCRATCH/project" \
    | HOME="$SCRATCH/home" CLAUDE_PROJECT_DIR="$SCRATCH/project" CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$cmd" 2>&1)
  rc=$?
  case "$out" in
    *"No such file"* | *"not found"*) bad "the script was not reached: $cmd" "$out" ;;
    *) if [ "$rc" -eq 0 ]; then ok "runs and exits 0: $cmd"; else bad "exit $rc: $cmd" "$out"; fi ;;
  esac
done < <(commands_of "$REPO/hooks/hooks.json")
if [ "$n" -eq 6 ]; then ok "6 hooks.json commands driven"; else bad "expected 6 hooks.json commands, drove $n"; fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
