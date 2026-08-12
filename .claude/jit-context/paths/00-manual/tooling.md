---
title: These five fail loudly, and their exit codes carry meaning
match: (^|/)(scripts/(rebuild-tsv|jit-dry-run|jit-misses|jit-init)\.sh|\.github/scripts/assemble_changelog\.py)$
---

`rebuild-tsv.sh`, `jit-dry-run.sh`, `jit-misses.sh`, `jit-init.sh` and `.github/scripts/assemble_changelog.py` are build, diagnostic and release tools. They are run deliberately, by a person or by CI, and never inside a stranger's session.

**So `paths/00-manual/hooks.md` does not apply here, and following it would be the bug.** "Every failure path exits `0` with nothing injected" is the hook contract; obeying it in `rebuild-tsv.sh` produces a half-written index that nothing reports, which is the exact defect this plugin exists to prevent. Fail loudly instead: a tool that cannot do its job must say so, on stderr, with a non-zero status.

**Three outcomes, never two.** Each of these already distinguishes "nothing to report" from "could not evaluate", and that distinction is load-bearing — an empty report meaning both at once is this repository's own defect class.

| Script | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `jit-dry-run.sh` | every pattern honourable, every index current, every `config.env` line honoured | at least one pattern refused, or a `00-manual/` entry is `STALE` — you did not rebuild | could not evaluate the tree at all. Never a pass. |
| `jit-misses.sh` | findings, **or** the log was read and nothing recurs — the two are distinguished in the text, not the status | — | `SKIPPED`, with a named reason |
| `rebuild-tsv.sh` | the index was written and every row can be honoured | the index was written, and at least one row will be **refused** by the matcher — a `~@macro` it could not expand, written through unexpanded | could not build the index: no `tools/`, `paths/` or `vocabulary/` under `JIT_BASE`, or an index file it could not write |
| `jit-init.sh` | the starter entry was seeded **and** the index rebuilt, so it is live rather than inert | the entry is already there — a copy the user edited is not ours to replace — or the rebuild did not complete | a bad argument, a `--base` that is not a `<project>/.claude/jit-context` path, a linked component on the way in, an install carrying no template, or a directory that could not be created |
| `assemble_changelog.py` | assembled, or `--check` found nothing to refuse | a fragment or the request was refused — bad filename, unknown section, a body that does not name its own issue, a fragment the CommonMark guard rejects, an entry count that did not balance, or a `--version` disagreeing with `plugin.json` | could not evaluate: no `changelog.d/`, no `CHANGELOG.md`, no `[Unreleased]` heading, an unreadable `plugin.json`, nothing to assemble, **or `markdown-it-py` not importable** |

**`assemble_changelog.py` is Python and that is not the runtime rule being broken.** The `bash`/`awk`/`perl` promise is about the hooks, which run in a stranger's session; this runs in CI and at a tag. It lives under `.github/` rather than `scripts/` so the separation is structural — nothing in `.github/` ships inside the plugin — and its exit codes were **swapped** on the way over from `claude-supertool`, whose script uses 1 for skipped and 2 for refused. A fifth tool here with inverted codes is exactly the trap this repository exists to describe.

Its guard is a real CommonMark parser and there is deliberately **no text-scanning fallback**: three pattern-based scanners upstream were each bypassed within one audit. So a missing `markdown-it-py` is `2`, never `0` — "did not look" must never render as "looked and found nothing".

`--version` is an argument *and* is verified against the manifest: reading it out of `plugin.json` would make the `CHANGELOG.md` heading a copy of that file, and `tests/test-version-sites.sh` compares exactly those two — the guard would then be asserting only that this script ran.

A `WARN` row in `jit-dry-run.sh` never moves the exit code, and neither does `rebuild-tsv.sh`'s **advisory** ambiguous-keyword tally. Those entries are indexed and fire correctly; nothing about them is refused, and failing on them would make the documented default tree exit non-zero and teach every author to ignore the status. If you add a check, decide which of the three it is before you write it.

`rebuild-tsv.sh`'s codes were only added in #47 — until then it reported a refused macro on stderr and exited `0`, so CI could not tell a clean rebuild from one that indexed a pattern the hook will refuse. Two things about them are worth knowing before you change them:

- **`1` is not a general lint tally.** `jit_expand_match()` returns 0 for every value that is not a macro, so the only way to reach `1` is a `~@macro` an author wrote and got wrong. That is why there is no `--strict` flag: the `&&` chain that stops belongs to the person who just wrote the dead rule, and a flag only CI passes would hand that person back the exit `0` that was the bug.
- **`2` cannot be `[ -d "$JIT_BASE" ]`.** `common.sh` `mkdir -p`s `$JIT_BASE/.discovery/logs` when it is sourced, so the base directory exists by the time this script runs even in a project with no entry tree at all. The guard asks whether any **dimension** directory is there.

**`rebuild-tsv.sh` is the only writer of `00-index.tsv`.** The markdown is the source; the TSV is what the hooks read, and nothing else may write it — `tools/00-manual/no-hand-editing-the-index.md` blocks the edit. It also expands the `~@invocation` macros into real EREs, so a macro it does not know is refused, named, and written through unexpanded, which makes the hook refuse that row too rather than silently match nothing.

**`jit-init.sh` does not source `common.sh` either, and for the same reason.** `common.sh` resolves `JIT_BASE` from `$CLAUDE_PROJECT_DIR` and `mkdir -p`s a log directory under it at load; the tree `jit-init.sh` seeds is the one `--base` names, which need not be that project. A tool that creates a directory in a third place on the way to creating one where you asked is a tool whose receipt lies. It writes exactly one entry, copied from `templates/jit-context/`, and **refuses rather than overwrites** — the copy in the project belongs to whoever edited it (#81).

**`jit-misses.sh` does not source `common.sh`, on purpose.** `common.sh` `mkdir -p`s the log directory at load, and a reporting tool that creates the thing it reports is a tool whose own output cannot be trusted. Do not "fix" the missing `source` line. `rebuild-tsv.sh` and `jit-dry-run.sh` do source it — and a change you make *inside* `common.sh` is governed by `hooks.md`, not by this file.

**`jit-misses.sh` reads a file the hooks wrote, so its `awk` is pinned to `LC_ALL=C` too.** The hooks truncate the prompt copy at 80 **bytes**, so an ordinary CJK or heavily accented prompt leaves a half-finished UTF-8 sequence at the end of a log line — no attacker, no malformed input. Reading that back aborted this tool with `illegal byte sequence` under one-true-awk and made gawk warn (#68, one hop downstream from the hooks). Failing loudly is this file's contract, and it still holds — a log this tool cannot read gets a named `SKIPPED` and exit 2. Choking on bytes the plugin wrote itself is not that. The fold table here is the byte-identical copy of `common.sh`'s, `index()`/`substr()` with no decode and both cases listed, so `C` costs it nothing.

**No new runtime dependencies, same as the hooks.** `awk` and `perl` only. No `jq`, no Python, no Node. These ship inside the plugin and run on Linux, macOS and Windows (Git Bash); `find -delete` is not POSIX and GNU-only flags are not available.

**`match` is an awk ERE.** `\s` `\d` `\w` compile to the bare letter and match nothing; `\b` is a backspace character. `rebuild-tsv.sh` writes the pattern and `jit-dry-run.sh` lints it, so both ends of that guard live here.

Which suite covers what — run the one you touched, then `tests/run-all.sh`:

```bash
bash tests/test-jit-dry-run.sh        # jit-dry-run.sh: flags, exit codes, STALE detection
bash tests/test-jit-init.sh           # jit-init.sh: what it seeds, the refusal, and the entry both ways
bash tests/test-jit-misses.sh         # jit-misses.sh: the three outcomes
bash tests/test-rebuild-exit-codes.sh # rebuild-tsv.sh: 0/1/2, each against a fixture
bash tests/test-invocation-macro.sh   # rebuild-tsv.sh: macro expansion, and refusal
bash tests/test-frontmatter-quotes.sh # rebuild-tsv.sh: frontmatter parsing
bash tests/test-assemble-changelog.sh # assemble_changelog.py: the guard, every refusal, the count
bash tests/test-changelog-fragment-refs.sh # nothing names a fragment the next tag deletes
bash tests/test-dogfood-entries.sh    # this repo's own rules, both directions
bash tests/run-all.sh                 # non-zero on any failure
```

**A suite that drives `rebuild-tsv.sh` over a deliberately broken fixture must not run under `set -e`.** `test-invocation-macro.sh` and `test-frontmatter-quotes.sh` each build a tree containing a macro the writer refuses, on purpose — since #47 that rebuild exits `1`, and `set -e` would abort the suite at the fixture it exists to construct. They use `set -uo pipefail` for that reason; adding the `-e` most other suites carry is the tidy-up that breaks them.

**Write the test first and watch it fail.** A test written after the fix asserts what the code happens to do. `paths/00-manual/tests.md` fires when you open the suite and carries what makes an assertion here non-vacuous.
