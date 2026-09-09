#!/usr/bin/env bash
# .oss/statusline.py resolves argv[0] before running supertool, in every call site.
#
# #380. `_run()` resolves through `_safe_which()` so a same-named `supertool.exe` /
# `supertool.cmd` planted at the root of the repository the statusline is reporting on
# cannot beat a real PATH entry on Windows, where a bare argv[0] with no directory
# component lets CreateProcess search the calling process's own current directory first.
# `_run_channel_health()` deliberately does not go through `_run` -- it needs the four
# non-zero `channel:health` states that `_run` folds into one None -- and that opt-out
# silently took the resolution with it.
#
# This suite guards a patch that is temporary BY CONSTRUCTION. `.oss/` is vendored from
# the oss plugin and replaced wholesale by `/oss:scaffold --apply`, so the fix reaches
# this tree only until the next scaffold run; the durable one is claude-oss#1399. tests/
# is not scaffold-owned, so this file survives that run and goes red the moment a
# scaffold reintroduces the bare argv[0]. That red IS the point of the suite: it is the
# only thing standing between an overwritten patch and a silently reopened hole.
#
# The assertion drives the real function rather than grepping for a call, because a grep
# for `_safe_which` passes on a file that mentions it in a comment and never calls it.
#
# jit-drive: none -- every assertion here drives statusline.py in-process and takes no hook output

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR" || {
  echo "SKIPPED: cannot reach the repository root"
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "SKIPPED: no python3 on PATH -- .oss/statusline.py could not be driven at all"
  exit 2
}

[ -r .oss/statusline.py ] || {
  echo "SKIPPED: .oss/statusline.py is not readable here"
  exit 2
}

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "ok   - $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1: $2"
}

# Loads a copy of statusline.py, replaces `_safe_which` with one that returns a sentinel
# absolute path, replaces `subprocess.run` with one that records argv and returns an
# empty result, then calls the target function. Prints the argv[0] that was reached, or a
# marker. $1 is the file to drive.
drive() {
  python3 - "$1" <<'PY' 2>&1
import importlib.util, subprocess, sys, types

SENTINEL = "/sentinel/bin/supertool"
path = sys.argv[1]

spec = importlib.util.spec_from_file_location("statusline_under_test", path)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as exc:  # noqa: BLE001 -- the suite reports it rather than dying
    print("LOAD-FAILED:%s" % exc)
    sys.exit(0)

if not hasattr(mod, "_run_channel_health"):
    print("NO-FUNCTION")
    sys.exit(0)

seen = []

def fake_run(command, **kwargs):
    seen.append(list(command))
    return types.SimpleNamespace(stdout=b"", returncode=0)

mod._safe_which = lambda name: SENTINEL
mod.subprocess = types.SimpleNamespace(
    run=fake_run,
    PIPE=subprocess.PIPE,
    DEVNULL=subprocess.DEVNULL,
    SubprocessError=subprocess.SubprocessError,
)

mod._run_channel_health()

if not seen:
    print("NO-CALL")
else:
    print("ARGV0:%s" % seen[0][0])
PY
}

echo "=== positive control: the harness reaches the function and records a call ==="
# Without this, every assertion below passes for a tree where nothing ran at all.
CONTROL="$(drive .oss/statusline.py)"
case "$CONTROL" in
  ARGV0:*) pass "the harness drove _run_channel_health and captured its argv" ;;
  *)
    echo "SKIPPED: the harness could not drive _run_channel_health ($CONTROL)."
    echo "SKIPPED: every assertion below would be vacuous, so none of them ran."
    exit 2
    ;;
esac

echo "=== the call resolves argv[0] rather than passing a bare name ==="
case "$CONTROL" in
  ARGV0:/sentinel/bin/supertool)
    pass "_run_channel_health runs the path _safe_which resolved"
    ;;
  ARGV0:supertool)
    fail "_run_channel_health runs a bare argv[0]" \
      "got 'supertool'; a same-named file at the repo root wins over PATH on Windows (#380)"
    ;;
  *)
    fail "_run_channel_health reached an argv[0] this suite does not recognise" "$CONTROL"
    ;;
esac

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
