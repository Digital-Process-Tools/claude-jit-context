# Performance

_Part of [claude-jit-context](../README.md). Full reference, not the getting-started arc._

Every hook is a **single `awk` process**. Frontmatter is parsed at build time into TSV, so the runtime path is a flat file scan with no JSON parsing, no `jq`, and no subprocess per rule. Typical hook time is 30–110 ms, which matters because these run on _every_ prompt and _every_ tool call.

Timings and matches are appended to `.claude/jit-context/.discovery/logs/hooks.log`:

```
[23:48:14.393] pre-tool (Bash) 29ms | 10-auto:billing.md(billing)[full] [shown:11] << src/Billing/Totals.php
```

`(none)` in the match column means nothing fired — useful for finding knowledge gaps. The bracket after a match says what it cost: `[summary]`, `[full]`, `[full:block]`, or `[summary:no-description]` for an entry that could only be named.

A `:badmode` suffix on any of those — `[full:badmode]`, `[summary:badmode]`, `[summary:no-description:badmode]` — says the entry did not ask for that mode: its `inject:` value was not `summary` or `full`, so the project default applied. The mode column used to say `[full]` either way, which meant the durable record could not tell a deliberate `full` from a typo nobody had noticed (#130). `grep badmode` over the log is the tally, and it counts entries that **fired** — an entry with a typo that never matched anything leaves no line here at all. `bash scripts/jit-dry-run.sh --base <tree>` finds those: it reads every entry rather than only the ones that fired, and prints an `ADVISORY` row naming each one (#147).

**`withheld[…]` names a match that was not delivered.** A `block` decision is the whole of the call's output, so the advisory rules and vocabulary entries that also matched that command are discarded — and they are therefore *not* spent: the next call in the session still gets them. They are listed apart from the delivered ones, and the `[shown:N]` count excludes them, so a blocked call can no longer read as a delivery that happened:

```
[23:48:14.393] pre-tool (Bash) 31ms | tool:nopush.md(git push)[full:block], withheld[00-manual:billing.md(billing)[full]] [shown:0] << src/Billing/Totals.php
```

That same log is how you find out whether the pull step is being taken, which is the question that decides whether `summary` was worth it. Reading an entry is a tool call, so it appears in the path column with no extra instrumentation:

```
[23:48:15.902] pre-path 11ms | (none) << .claude/jit-context/vocabulary/00-manual/billing.md
```

**Nothing is written in a project that has no `.claude/jit-context/` directory.** The
plugin installs globally and then runs in every repository you open, so it creates nothing
until you have opted in by making that directory — `bash scripts/jit-init.sh`, or a
`mkdir` of your own. Until then all six hooks run, match nothing, log nothing and exit 0,
and `git status` in a project that never asked for any of this stays clean. Once the
directory exists, the log and the once-per-session markers live under
`.claude/jit-context/.discovery/`, which is a good line for your `.gitignore`:

```gitignore
.claude/jit-context/.discovery/
```

**A log line is capped at 2048 bytes of matches, and says how many it dropped.** An index
with hundreds of rows that all match writes a name for each one, which measured between 16
and 22 KB per line on a 400-row tree — once per prompt and once per tool call. What fits is
written whole; the rest is accounted for rather than silently cut:

```
… tool:billing.md(billing), [+3442 bytes not listed here; this line is capped at 2048 bytes -- scripts/jit-dry-run.sh prints the whole tree] [shown:0] << src/Billing/Totals.php
```

The trailing `[shown:N] << …` field is never cut — it is what `jit-misses.sh` reads.

**If any part of that path is a symbolic link, logging is switched off for the run and the
hooks carry on.** The log path is built inside the project, so a cloned repository would
otherwise choose the file the hooks append to — and `mkdir -p` and `>>` both follow a link.
A hook that cannot log still has a job to do, so nothing fails and nothing is injected
about it; no log line arriving in a tree that has entries is the symptom. The one line a
refused row contributes never carries the raw file-name column from the index either, for a
name that failed the containment check: that is unvalidated text from the repository, and
this file is read by a person.

