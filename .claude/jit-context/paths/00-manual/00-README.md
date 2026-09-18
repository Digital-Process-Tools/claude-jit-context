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
