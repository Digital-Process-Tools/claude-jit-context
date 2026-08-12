---
title: How jit-context matching works
description: The three dimensions, the TSV index between markdown and the hooks, and the layer order.
keywords: jit-context, jit context, 00-index, rebuild-tsv, pre-path-hook, pre-prompt-hook, pre-tool-hook, session-start-hook, invocation macro, jit-dry-run
---

Three dimensions, one hook each. Knowledge attaches to whichever trigger answers _when the reader needs it_.

| Dimension  | Fires on                    | Hook                 | Entries in                        |
| ---------- | --------------------------- | -------------------- | --------------------------------- |
| vocabulary | keywords in the prompt      | `pre-prompt-hook.sh` | `.claude/jit-context/vocabulary/` |
| paths      | a file path being touched   | `pre-path-hook.sh`   | `.claude/jit-context/paths/`      |
| tools      | tool name + command pattern | `pre-tool-hook.sh`   | `.claude/jit-context/tools/`      |

Tools is the only dimension that can `block`. The other two only inject. Each entry fires at most once per session; the marker is keyed on the payload's `session_id` and lives in `.claude/jit-context/.discovery/state/`, and `session-start-hook.sh` clears this session's and ages out the rest. A payload with no `session_id` — a hand-run hook, every test suite here — keeps no marker and therefore never dedups.

A match injects the entry body whole — `full` is the default, kept so an upgrade cannot silently take away knowledge a project already relies on. `JIT_CONTEXT_INJECT=summary` in `config.env`, or `inject: summary` in one entry, injects `title:` plus `description:` instead, about 20 tokens, and the agent reads the file if it wants the rest. `rebuild-tsv.sh` prices one match on the tree and names the entries with no `description:` yet; `jit-dry-run.sh` reports the bytes a sample call actually injected. A refusing tools rule always injects its whole body.

Layers are scanned in order inside each dimension: `00-manual/` (hand-written), then `10-auto/`, `20-grouped/`, `30-crosscutting/` (generated). A project with no generator uses `00-manual/` alone.

Path rules also parse `Bash` commands: any token containing `/` is treated as a path, including paths lifted out of quoted `supertool` arguments. A command with no path in it matches nothing — deliberately, so a stray word in a commit message cannot drag an entry into context.

A tools `match` may be a substring, a `~`-prefixed awk ERE, or an invocation macro — `~@invocation git push`, `~@invocation-quoted-arg supertool` — which `rebuild-tsv.sh` expands into the ERE at index time. `jit-dry-run.sh` lints one tree and reports `REFUSED` (a pattern the matcher cannot honour) and `STALE` (frontmatter the index does not carry).

Timings and matches land in `.claude/jit-context/.discovery/logs/hooks.log`. `(none)` in the match column marks a knowledge gap.

```
[23:48:14.393] pre-tool (Bash) 29ms | 10-auto/billing.md(billing) [shown:11] << src/Billing/Totals.php
```
