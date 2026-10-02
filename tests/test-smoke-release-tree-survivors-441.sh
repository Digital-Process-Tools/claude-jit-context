#!/bin/bash
# #441: smoke_release_tree.py's _survivors() must never read "ps could not be run" the
# same way as "ps ran and found nothing". Before this fix, OSError (no `ps` on PATH)
# hit `except OSError: return []`, and `_reap()`'s very first poll treated that empty
# list as "clean" and returned without ever actually checking a process or surfacing
# an error. The bug is latent on ubuntu-latest, which has `ps`, so nothing in CI today
# would have caught a regression here.
#
# Both directions, same fixture: a positive control where `ps` genuinely runs and is
# read as a real (possibly empty) answer, and the negative where it cannot be run at
# all and must come back as could-not-tell, surfaced as a result.errors entry that
# makes result.ok False -- never as a silent, vacuous "clean".
#
# Usage: bash tests/test-smoke-release-tree-survivors-441.sh
#
# jit-drive: none -- this drives functions inside smoke_release_tree.py directly, not
# a hook.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE="$REPO/.github/scripts/smoke_release_tree.py"

[ -f "$SMOKE" ] || {
  echo "FAIL: harness guard -- $SMOKE does not exist, every assertion below is vacuous"
  exit 1
}
if ! command -v python3 > /dev/null 2>&1; then
  echo "SKIPPED: no python3 on PATH -- this script is not part of the hook runtime"
  exit 0
fi

OUT=$(
  python3 - "$SMOKE" << 'PY'
import importlib.util
import sys
from unittest import mock

smoke_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("smoke_release_tree", smoke_path)
smoke = importlib.util.module_from_spec(spec)
# dataclasses resolves annotations via sys.modules[cls.__module__] at class-creation
# time, so the module must be registered there BEFORE exec_module runs the @dataclass
# decorator inside it, or it looks up None and crashes on an unrelated AttributeError.
sys.modules["smoke_release_tree"] = smoke
spec.loader.exec_module(smoke)

PASS = 0
FAIL = 0


def ok(desc):
    global PASS
    PASS += 1
    print(f"  PASS: {desc}")


def bad(desc, *detail):
    global FAIL
    FAIL += 1
    print(f"  FAIL: {desc}")
    for d in detail:
        print(f"    {d}")


# --- positive control: ps genuinely runs ------------------------------------------
# Real `ps` on this machine, no process matches our bogus pgid/marker -- the honest
# "found nothing" answer, which must be an EMPTY LIST, not None.
survivors = smoke._survivors(set(), "no-such-marker-441-xyz")
if survivors == []:
    ok("a real `ps` run with nothing matching returns an empty list, not None")
else:
    bad("a real `ps` run with nothing matching returns an empty list, not None",
        f"got: {survivors!r}")

# --- negative: ps cannot be run at all ---------------------------------------------
with mock.patch.object(smoke.subprocess, "run", side_effect=OSError("no such file")):
    could_not_tell = smoke._survivors(set(), "marker")
if could_not_tell is None:
    ok("ps raising OSError comes back as None, not an empty list")
else:
    bad("ps raising OSError comes back as None, not an empty list",
        f"got: {could_not_tell!r} -- this is the #441 bug: a missing `ps` reads as clean")

# Positive control for the control above: an _reap() call that CAN see real output
# must not report an error and must return promptly (no survivors to wait out).
result_clean = smoke.SmokeResult()
smoke._reap(set(), "no-such-marker-441-xyz", 1.0, result_clean)
if result_clean.errors == [] and result_clean.ok:
    ok("_reap() with a working `ps` and nothing to reap reports no error")
else:
    bad("_reap() with a working `ps` and nothing to reap reports no error",
        f"errors: {result_clean.errors!r}, ok: {result_clean.ok}")

# The bug itself, through the real caller: _reap() must surface the could-not-tell
# state as an error (so result.ok is False) rather than returning silently clean.
result_blind = smoke.SmokeResult()
with mock.patch.object(smoke.subprocess, "run", side_effect=OSError("no such file: ps")):
    smoke._reap(set(), "marker", 1.0, result_blind)
if result_blind.errors and not result_blind.ok:
    ok("_reap() with `ps` unavailable reports an error and is not ok")
else:
    bad("_reap() with `ps` unavailable reports an error and is not ok",
        f"errors: {result_blind.errors!r}, ok: {result_blind.ok}",
        "a missing `ps` must never let this smoke run report clean (#441)")

print("========================")
print(f"  {PASS}/{PASS + FAIL} passed, {FAIL} failed")
print("========================")
sys.exit(0 if FAIL == 0 else 1)
PY
)
RC=$?
echo "$OUT"
exit "$RC"
