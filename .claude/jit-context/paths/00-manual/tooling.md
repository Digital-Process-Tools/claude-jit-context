---
title: These three fail loudly, and their exit codes carry meaning
match: (^|/)scripts/(rebuild-tsv|jit-dry-run|jit-misses)\.sh$
---

`rebuild-tsv.sh`, `jit-dry-run.sh` and `jit-misses.sh` are build and diagnostic tools. They are run deliberately, by a person or by CI, and never inside a stranger's session.

**So `paths/00-manual/hooks.md` does not apply here, and following it would be the bug.** "Every failure path exits `0` with nothing injected" is the hook contract; obeying it in `rebuild-tsv.sh` produces a half-written index that nothing reports, which is the exact defect this plugin exists to prevent. Fail loudly instead: a tool that cannot do its job must say so, on stderr, with a non-zero status.

**Three outcomes, never two.** Each of these already distinguishes "nothing to report" from "could not evaluate", and that distinction is load-bearing — an empty report meaning both at once is this repository's own defect class.

| Script | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `jit-dry-run.sh` | every pattern honourable, every index current, every `config.env` line honoured | at least one pattern refused, or a `00-manual/` entry is `STALE` — you did not rebuild | could not evaluate the tree at all. Never a pass. |
| `jit-misses.sh` | findings, **or** the log was read and nothing recurs — the two are distinguished in the text, not the status | — | `SKIPPED`, with a named reason |
| `rebuild-tsv.sh` | **every path, including a refused macro** — measured 2026-08-12, it has no non-zero exit at all | — | — |

A `WARN` row in `jit-dry-run.sh` never moves the exit code. If you add a check, decide which of the three it is before you write it.

That `rebuild-tsv.sh` row is a gap, not a design. It reports a refused macro on stderr and then exits `0`, so CI cannot tell a clean rebuild from one that indexed a pattern the hook will refuse — the rule reads as enforced and never fires, which is the whole failure this repository is about. If you are already in this file for another reason, that is the fix to make; do not import the hook's exit-`0` contract as a justification for leaving it.

**`rebuild-tsv.sh` is the only writer of `00-index.tsv`.** The markdown is the source; the TSV is what the hooks read, and nothing else may write it — `tools/00-manual/no-hand-editing-the-index.md` blocks the edit. It also expands the `~@invocation` macros into real EREs, so a macro it does not know is refused, named, and written through unexpanded, which makes the hook refuse that row too rather than silently match nothing.

**`jit-misses.sh` does not source `common.sh`, on purpose.** `common.sh` `mkdir -p`s the log directory at load, and a reporting tool that creates the thing it reports is a tool whose own output cannot be trusted. Do not "fix" the missing `source` line. `rebuild-tsv.sh` and `jit-dry-run.sh` do source it — and a change you make *inside* `common.sh` is governed by `hooks.md`, not by this file.

**No new runtime dependencies, same as the hooks.** `awk` and `perl` only. No `jq`, no Python, no Node. These ship inside the plugin and run on Linux, macOS and Windows (Git Bash); `find -delete` is not POSIX and GNU-only flags are not available.

**`match` is an awk ERE.** `\s` `\d` `\w` compile to the bare letter and match nothing; `\b` is a backspace character. `rebuild-tsv.sh` writes the pattern and `jit-dry-run.sh` lints it, so both ends of that guard live here.

Which suite covers what — run the one you touched, then `tests/run-all.sh`:

```bash
bash tests/test-jit-dry-run.sh        # jit-dry-run.sh: flags, exit codes, STALE detection
bash tests/test-jit-misses.sh         # jit-misses.sh: the three outcomes
bash tests/test-invocation-macro.sh   # rebuild-tsv.sh: macro expansion, and refusal
bash tests/test-frontmatter-quotes.sh # rebuild-tsv.sh: frontmatter parsing
bash tests/test-dogfood-entries.sh    # this repo's own rules, both directions
bash tests/run-all.sh                 # non-zero on any failure
```

**Write the test first and watch it fail.** A test written after the fix asserts what the code happens to do. `paths/00-manual/tests.md` fires when you open the suite and carries what makes an assertion here non-vacuous.
