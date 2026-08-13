---
title: A green suite that tested nothing is the failure mode here
description: How to make an assertion here non-vacuous - the harness guard that proves the suite can see its tree, pairing every silence with a match, and the awk engine matrix.
match: (^|/)tests/[^/]*\.sh$
---

Every suite in this directory has one job the assertions do not state: prove it could see the thing it is asserting about. Three suites in one week reported green while testing nothing — including one written to catch exactly that defect.

**A negative assertion needs a positive control on the same shape.** "Nothing was written outside the tree", "the rule did not fire", "no entry was injected" are all true when *nothing happened at all* — a typo in the payload, a hook that exited early, a harness pointed at an empty tree. Measured cases:

- `test-log-containment.sh` reported **30/30 on Windows with four sections testing nothing**; 17 of the 30 assertions were vacuous, because a copied `hooks.log` lives inside the project and "nothing was appended to the victim file" is then true for a reason unrelated to the guard.
- `test-dogfood-entries.sh` passed every `assert_silent` in its first draft because it resolved the tree from the working directory, so **every** sample returned nothing.

So pair each negative with a positive on the same code path, and put the control *first*: if it goes red, the suite must say in as many words that everything below it is vacuous. `test-dogfood-entries.sh` exits before its assertions when the harness cannot evaluate this repo's own tree; `test-log-containment.sh` and `test-symlink-entry.sh` do the same per section. Copy that shape rather than inventing a new one.

The question to ask of anything you add: **would this still pass if the code did nothing?** If yes, it is not a test.

**Three outcomes, never two.** `run-all.sh` reads `0` pass, `2` could-not-build-its-fixtures, anything else fail. A suite that cannot construct the attack it exists to refuse — `ln -s` copies instead of linking on Windows — exits `2` and prints a `SKIPPED` block naming what went untested. Folding that into a pass prints a sentence about coverage nobody has.

**`$( )` silently drops NUL bytes.** An assertion reading a captured variable passes against hook output containing a raw `0x00`. Write the hook output to a file and check the file:

```bash
bash "$HOOK" < payload.json > out.json 2>/dev/null
grep -q 'what you expect' out.json          # not: out=$(bash "$HOOK" ...)
```

**Never pipe into `grep -q`, or into `head`.** Both exit on the first match or the first N bytes; the writer on the left of the pipe is then writing into a closed pipe, takes `SIGPIPE`, and under `set -o pipefail` the pipeline reports non-zero *having found the string*. `assert_contains` then prints FAIL on a hit and `assert_not_contains` prints PASS on a hit — a false red and a false green from the same line. It is invisible until something makes the output longer than the pipe buffer, which is when someone is already debugging that other thing and will believe the verdict. The writer is not the cause: `printf` takes the signal exactly as `echo` does. Read from a here-string instead, and `${var:0:200}` instead of `| head -c 200`:

```bash
grep -qF "$expected" <<<"$output"      # not: echo "$output" | grep -qF "$expected"
out=$(fired_for "$path"); grep -q X <<<"$out"   # not: fired_for "$path" | grep -q X
```

`test-assertion-helpers.sh` drives every suite's real helpers with a 1 MB payload and fails on the shape structurally, so a reintroduction is caught rather than waiting for output to grow.

**Every suite declares what that harness may drive, and a suite that declares nothing is red.** It used to bind on the helper's *name* — any `assert_blocked()` was called as `(description, captured-output)`. A helper written in the file-reading shape above takes a needle and a path instead, so it was handed the 1 MB payload as a needle and reported as broken when it was not: a false red in the suite whose job is to catch false greens (#110). Declare each drivable helper on its own comment line, above its definition:

```bash
# jit-drive: assert_contains contains capture          # (desc, OUTPUT, needle)
# jit-drive: expect_blocked blocked file:OUT           # (desc, needle), reads "$OUT"
# jit-drive: assert_has contains path-arg              # (desc, PATH, needle)
# jit-drive: none -- every helper here runs the hook itself and takes no output argument
```

The semantic — `contains`, `not_contains`, `blocked`, `not_blocked`, `token_row`, `no_token_row` — is what the helper *means*, not what it is called; decoupling the two is the fix. Declaring the wrong one goes red, because the harness drives both directions and compares the verdict.

The three outcomes are `covered`, `flagged` and `not evaluated`, and the third is printed in full at the end of every run: the suites that declared `none` with their stated reason, and every `assert_*`/`expect_*` function nobody declared. Neither list fails the run — whether a helper is payload-shaped is not decidable from outside it — but a silent skip is not on offer either. Read that block when you add a helper; if yours is in it and should not be, it is one line.

**Engine-sensitive assertions run once per `awk` on the machine**, through a `PATH` shim that puts a one-line `exec` wrapper named `awk` ahead of `$PATH` for each of `awk gawk nawk mawk` that `command -v` finds, deduplicated by resolved path. The three `test-pre-*-hook.sh` suites and `test-jit-misses.sh` already build it. gawk and one-true-awk disagree on NUL transparency, on `split()` with a one-character separator, and on multibyte `substr`. Add such an assertion to that loop, not beside it.

**CI is Linux, macOS and Windows (Git Bash).** A green local run is evidence about one leg. Nothing here may assume GNU tools, a `/tmp` that behaves, a POSIX absolute path literal, or a bash newer than the one macOS ships.

```bash
bash tests/run-all.sh                                     # non-zero on any failure
shellcheck -S warning scripts/*.sh tests/*.sh             # a CI leg of its own
```

Fixtures build under `mktemp -d`, never in the repository tree — a suite that writes into the tree makes the next suite's result depend on the order they ran in. Clean up with a `trap`, not a line at the bottom: 12 of the 21 suites do — re-measured 2026-08-12 with `grep -l '^trap ' tests/test-*.sh | wc -l` — and the ones that do not leak a directory on every early exit. Re-measure rather than editing the number by hand; it was "seven of the sixteen" for long enough that both halves had drifted.
