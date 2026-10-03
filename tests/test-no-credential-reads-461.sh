#!/bin/bash
# #461: the Anthropic directory validator holds MCP_FORWARDS_CREDENTIAL_ENV when a
# shipped script "reads the installer's credential" and any script can "send data off
# the machine". Its fixHint names the way out: remove every part that reads a
# credential. The send side is not specific -- a runtime-built string such as
# "$JIT_NL$base$JIT_NL" counts -- so this suite guards the read side only.
#
# Each of these was named as the read, one validation after another, and the finding
# moved to the next one each time it was removed (measured on release-preview-m/-n2):
#   ${!sig:-}          an environment variable named at run time (host.sh)
#   env                "printenv / env / export -p / set" -- the bare word, here a
#                      regex alternative inside JIT_MACRO_WRAP, written [e]nv instead
#   $PWD               "reads the installer's PWD" -- `$(pwd)` gives the same path
#
# Comment lines are skipped: the build strips them, and the reason may name the
# construct. A sweep that finds nothing must be told apart from a pattern that never
# matches, so each needle is proven on a planted fixture first.
#
# Usage: bash tests/test-no-credential-reads-461.sh
#
# jit-drive: none -- this suite scans tracked files for a text shape; it defines no assertion helper

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
  shift
  [ $# -eq 0 ] || echo "    $*"
}

# One ERE per read the validator named. `${!name}` is indirect expansion; `${!arr[@]}`
# (the index list of an array) reads no environment variable and is not matched.
NEEDLES=(
  'indirect expansion|[$][{]![A-Za-z_][A-Za-z0-9_]*([}:]|$)'
  'PWD read|[$][{]?PWD([^A-Za-z0-9_]|$)'
  'environment dump word|(^|[^A-Za-z0-9_.-])(printenv|env|export[[:space:]]+-p)([^A-Za-z0-9_.=-]|$)'
)

# sweep FILE ERE -- "LINE: TEXT" for every non-comment line matching ERE.
sweep() {
  awk -v re="$2" '!/^[[:space:]]*#/ && $0 ~ re { print FNR ": " $0 }' "$1"
}

echo "=== controls: every needle matches its planted shape, and not the safe one ==="
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
printf '%s\n' \
  'if [ -n "${!sig:-}" ]; then' \
  'BASE="$PWD/.claude"' \
  'WRAP=(rtk|command|env|sudo)' \
  > "$fixture"
safe="$(mktemp)"
trap 'rm -f "$fixture" "$safe"' EXIT
printf '%s\n' \
  'for i in "${!ENTRY_FILENAME[@]}"; do' \
  'BASE="$(pwd)/.claude"' \
  'WRAP=(rtk|command|[e]nv|sudo)' \
  '# a comment may name $PWD and env' \
  'config.env is read' \
  > "$safe"
for entry in "${NEEDLES[@]}"; do
  label="${entry%%|*}"
  re="${entry#*|}"
  if [ -n "$(sweep "$fixture" "$re")" ]; then
    ok "control: $label matches its planted line"
  else
    bad "control: $label matches nothing planted -- every sweep below is vacuous for it"
  fi
  hits="$(sweep "$safe" "$re")"
  if [ -z "$hits" ]; then
    ok "control: $label leaves the safe shapes alone"
  else
    bad "control: $label flags a safe shape" "$hits"
  fi
done

echo ""
echo "=== no credential read in any shipped script ==="
for f in "$REPO"/scripts/*.sh; do
  for entry in "${NEEDLES[@]}"; do
    label="${entry%%|*}"
    re="${entry#*|}"
    hits="$(sweep "$f" "$re")"
    if [ -z "$hits" ]; then
      ok "$(basename "$f"): no $label"
    else
      bad "$(basename "$f"): $label" "$hits"
    fi
  done
done

echo ""
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
