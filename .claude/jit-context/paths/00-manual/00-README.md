# Declined traps — paths/00-manual

One line per trap this layer decided not to carry, so the next lane to hit the same thing sees
a decision rather than an absence. `rebuild-tsv.sh` skips this file by name, so nothing here is
ever indexed or injected.

- **host-sh-degraded-read-ambiguity** (2026-09-18, `trap.d/380.audit-non-blocking.md` item 1).
  `JIT_TOOL_ALIASES=""` collapses two different worlds (host.sh unreadable vs. every alias
  legitimately empty) and `JIT_HOST_REFUSAL_STATE` is set but read by no hook; `jit-doctor.sh`
  does not mention the host at all. Declined rather than promoted: a single non-blocking release
  audit finding, low reachability (host.sh ships beside common.sh), no fix decided at audit time,
  and `scripts/common.sh`'s own comments near `JIT_HOST_REFUSAL_STATE`/`JIT_TOOL_ALIASES` already
  name the collapse — a rule here would restate that comment rather than add a "before you touch
  X" step. Worth writing once whoever closes the doctor/hooks gap knows what the fix looks like.

- **windows-dev-fd-coverage-unknown** (2026-09-18, `trap.d/380.audit-non-blocking.md` item 3).
  Whether the `pre-tool-hook.sh` else-arm's `awk -f` on a `/dev/fd` path is actually exercised on
  `windows-latest` is contingent on item 2 (`tests/test-hook-tmpfile.sh` section C's missing
  `SKIPPED_SECTIONS` flag, merged into `tests.md` this pass) — nothing to assert until that
  section actually runs its assertions on that runner. Revisit once it does.

- **shared-debug-log-loses-writes** (2026-09-18, `trap.d/393.shared-debug-log-loses-writes-under-concurrent-load.md`).
  Already covered: `paths/00-manual/tests.md`'s "Concurrent lanes on one clone can crash a
  suite's own `awk`" section documents this exact instrumentation trap by name — a debug log
  shared across concurrent invocations losing writes under load — as part of the #393
  investigation it describes. Declined as a separate entry; a second copy here would duplicate
  content already in that file rather than add anything.

- **classifier-spawn-timeout-402** (2026-09-18, `trap.d/402.classifier-spawn-timeout.md`). A
  single tracker issue (#402) whose oss board classifier timed out after 45s — about the `oss`
  plugin's own tracker classifier infrastructure, not this repository's own code, and the
  fragment itself says "not chased further" and "worth a look if a second issue shows the same
  shape." One incident, no known trigger pattern in this repo's own paths/tools/vocabulary to
  match on. Revisit if a second issue repeats the same `could-not-classify` shape.

- **jit-misses-generic-words-v-escape** (2026-10-06, `trap.d/424.jit-misses-generic-words-v-escape.md`).
  Checked against HEAD (bda0282): already fixed. `scripts/jit-misses.sh` now compares the
  generic-word list by exact `FILENAME` membership in `isgenericfile[]`, built from
  `ENVIRON["GENERIC_ARG_FILES_ENV"]`, not from a `-v`-decoded path -- the same ENVIRON technique
  #437 used for `JIT_BASE`/`tools_base`/`vocab_base`, landed in `e0f8d39` (#437/#438). The
  remaining `-v logfile=`/`-v genname=` sites are cosmetic display text only, exactly as the
  fragment itself flagged.

- **rebuild-tsv-v-escape** (2026-10-06, `trap.d/424.rebuild-tsv-v-escape.md`). Two defects, one
  outcome each. The `GENERIC_WORDS_FILE`/`wf` site: already fixed, same commit (`e0f8d39`,
  #437/#438) -- `scripts/rebuild-tsv.sh` now splits `ENVIRON["GENERIC_WORDS_FILES"]` rather than
  reading a `-v`-decoded `wf`. The `layerdir`/`bytesof()` site (the vocabulary byte-count
  report): still true -- `layerdir` still reaches `bytesof()` via `-v layerdir=...` at HEAD.
  Filed Digital-Process-Tools/claude-jit-context#475.

- **wrong-worktree-edits** (2026-10-06, `trap.d/437.wrong-worktree-edits.md`). A lesson about
  forgetting a per-call `cd <worktree> &&` prefix, not a code defect. Declined here rather than
  promoted: the mitigation the fragment itself names -- the supertool write op's own
  `[branch: ...]` receipt line -- already surfaces exactly this after the fact, on every write,
  for free. A jit-context reminder would have to fire on every `edit`/`paste`/`batch` call in
  the whole repository (no ERE can tell "has a same-call `cd` prefix" from "does not" without
  lookbehind) to catch the rare miss, which is a worse trade than reading the receipt that is
  already there. See the parallel `tools/00-manual/00-README.md` entry for the tools-dimension
  side of this same decision.

- **awk-pipe-failure-masked-by-or-true** (2026-10-06, `trap.d/459.awk-pipe-failure-masked-by-or-true.md`).
  Checked against HEAD (bda0282): still true. `tests/test-no-heredocs-459.sh`'s
  `detect_heredoc_lines()` still pipes `awk ... | grep -nE -- "$HEREDOC_PATTERN" || true`, so an
  `awk` crash and a genuinely clean file still render identically. Non-blocking, narrow, one
  test's own shape. Filed Digital-Process-Tools/claude-jit-context#478.

- **release-check-crash-reads-as-pass** (2026-10-06, `trap.d/461.release-check-crash-reads-as-pass.md`).
  Checked against HEAD (bda0282): still true in both `tests/test-release-branch-461.sh` and
  `tests/test-release-branch-437.sh` -- a `check_release_tree.py` crash with no `FAIL ` line
  still reads as a pass in both. CI is covered separately; this is a local-run-only gap. Filed
  Digital-Process-Tools/claude-jit-context#476.

- **release-equivalence-builds-head-not-source-ref** (2026-10-06,
  `trap.d/461.release-equivalence-builds-head-not-source-ref.md`). Checked against HEAD
  (bda0282): still true. `tests/test-release-branch-461.sh` still builds `--ref HEAD` while
  `.github/workflows/release-branch.yml` publishes `$SOURCE_REF`, so a `workflow_dispatch` run
  against an older ref still checks the wrong tree's equivalence. Filed
  Digital-Process-Tools/claude-jit-context#477.

- **privacy-page-claims-vs-code** (2026-10-06, `trap.d/466.privacy-page-claims-vs-code.md`).
  Checked against HEAD (bda0282): already fixed. All four claims (F1 opt-in scope, F2 the
  120-byte field, F3 `bytes-shown-*` aging, F4 `jit_worktree_mismatch_line`'s own read) are
  stated correctly in `PRIVACY.md` as it reads now, landed in `1db1603` (#466/#468) and
  `7046d0a` (#466/#470).
