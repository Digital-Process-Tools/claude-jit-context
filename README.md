# claude-jit-context

[![Tests](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml/badge.svg)](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml)
[![Shell](https://img.shields.io/badge/bash-4%2B-blue)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/tested%20on-Linux%20%7C%20macOS-blue)](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Community-brightgreen)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.0-orange)](.claude-plugin/plugin.json)

Project knowledge that loads **only when it is needed**.

Everything in `.claude/rules/` loads at session start — every file, every session, whether or not the session touches the code it describes. Ten rule files is thousands of tokens spent before the first question is asked. `CLAUDE.md` has the same problem: it grows, and all of it is resident all the time.

claude-jit-context moves that knowledge behind pattern matching. A note about database migrations loads when someone opens a migration — not before. A gotcha about your billing module loads when the prompt mentions billing. A session that never touches PHP never pays for the PHP conventions.

Nothing loads speculatively. Nothing is resident.

## Install

### From our marketplace (recommended)

```
/plugin marketplace add Digital-Process-Tools/claude-marketplace
/plugin install claude-jit-context@dpt-plugins
```

To update later:

```
/plugin marketplace update
```

**Restart Claude Code after installing.** Hook registrations are read at session start, so a plugin enabled mid-session has no hooks wired for the rest of it.

### Manual

Copy this directory to `<your-project>/.claude/claude-jit-context/` and register the hooks in `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/claude-jit-context/scripts/session-start-hook.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/claude-jit-context/scripts/pre-prompt-hook.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/claude-jit-context/scripts/pre-tool-hook.sh"
          }
        ]
      },
      {
        "matcher": "Read|Edit|Write|Glob|Grep|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/claude-jit-context/scripts/pre-path-hook.sh"
          }
        ]
      }
    ]
  }
}
```

### Requirements

Bash 4+, `awk`, `perl` (used only for millisecond timestamps). **No `jq`, no Python, no Node.** Linux and macOS; Windows is not supported.

## The three dimensions

Knowledge attaches to one of three triggers. Pick by asking _when_ the reader needs it.

| Dimension      | Fires on                      | Hook                 | Lives in                      |
| -------------- | ----------------------------- | -------------------- | ----------------------------- |
| **Vocabulary** | keywords in the prompt        | `pre-prompt-hook.sh` | `.claude/jit-context/vocabulary/` |
| **Paths**      | a file path being touched     | `pre-path-hook.sh`   | `.claude/jit-context/paths/`      |
| **Tools**      | a tool name + command pattern | `pre-tool-hook.sh`   | `.claude/jit-context/tools/`      |

Vocabulary answers _"what are we talking about?"_ — the billing module, the deploy process, that one flaky test.
Paths answer _"what shape must this file have?"_ — the conventions for anything under `Commands/`.
Tools answer _"what must happen around this action?"_ — required flags on a test command, a checklist before `git push`.

The tool dimension is the only one that can **block**. The other two only inject.

## Writing an entry

Every entry is a markdown file with YAML frontmatter, in `00-manual/`. The frontmatter is the only structured part; the body is free-form and goes into context verbatim.

### Vocabulary

```markdown
---
title: Billing amounts
description: How invoice totals are computed, and why the entity getter lies.
keywords: billing, invoice, amount, vat, total
---

Totals are **not** stored. `getAmountVatOut()` is overridden by `BillingTotalsTrait`
and recomputed from line items on every call (`src/Billing/Totals.php:88`).

Writing to `amount_vat_out` directly appears to work and is silently discarded on
the next read.
```

### Paths

```markdown
---
title: Command conventions
match: Commands/
---

Every command extends `CommandBase` and implements `declareOptions()`.
Return values are typed — never `void`, because callers assert on the result.
```

`match` is a regex tested against the file path.

### Tools

```markdown
---
title: Always disable coverage locally
tool: Bash
match: bin/phpunit
mode: remind
forbid: --coverage-html
---

Coverage runs take 8 minutes locally and are produced by CI anyway.
```

| Field     | Required | Meaning                                                           |
| --------- | -------- | ----------------------------------------------------------------- |
| `tool`    | yes      | Tool name: `Bash`, `Read`, `Edit`, `Skill`, `Task`, …             |
| `match`   | yes      | Substring, or a regex when prefixed with `~`                      |
| `mode`    | no       | `remind` (default), `block`, `once` — comma-separated, composable |
| `require` | no       | Pipe-separated strings that MUST appear, else the call is blocked |
| `forbid`  | no       | Pipe-separated strings that must NOT appear, else blocked         |

| Mode     | Effect                                                  |
| -------- | ------------------------------------------------------- |
| `remind` | Injects the file body as additional context             |
| `block`  | Rejects the tool call, returning the body as the reason |
| `once`   | Fires at most once per session                          |

### Batched file operations

Path rules read `file_path` from `Read`/`Edit`/`Write`/`Glob`/`Grep`. They also parse `Bash` commands that invoke [supertool](https://github.com/Digital-Process-Tools/claude-supertool), lifting the paths out of its quoted arguments — so

```bash
./supertool 'read:src/Billing/Totals.php' 'grep:getAmount:src/Billing/:10'
```

still fires the rules for `src/Billing/`. Without this, batching file operations would silently bypass every path rule you have written.

More generally, any path-like token (anything containing `/`) in a Bash command is considered. Commands with no path in them match nothing — deliberately, so that a stray word in a commit message cannot drag an unrelated entry into context.

## Rebuild after every edit

Entries do nothing until they are indexed:

```bash
bash .claude/claude-jit-context/scripts/rebuild-tsv.sh
```

This parses the frontmatter of every `.md` file into `00-index.tsv` files, which is what the hooks actually read. It also prints an **ambiguity report** — keywords appearing in more than five entries. Those are worth pruning: every match loads the whole entry, so a keyword like `user` in twelve files means one stray mention drags twelve files into context.

### Verify an entry actually fires

An entry that never fires looks exactly like work that was done.

```bash
echo '{"prompt":"how do invoice totals work"}' \
  | bash .claude/claude-jit-context/scripts/pre-prompt-hook.sh
```

`{}` means no match — the keywords are wrong.

## How keyword matching works

Understanding this is the difference between entries that fire and entries that sit there.

Before matching, the prompt is normalized: **CamelCase is split** (`BillingModule` becomes `Billing Module`), everything is **lowercased**, and every character outside `[a-z0-9 -]` becomes a space. Matching is then **space-bounded** — the keyword must sit on whole-word boundaries.

Consequences worth internalizing:

- `microbilling` does **not** match the keyword `billing`. This is deliberate; substring matching made short keywords fire on everything.
- A keyword containing dots or slashes — `docs.example.com`, `security/audit` — can never match a raw prompt, because those characters are stripped before comparison. `rebuild-tsv.sh` normalizes keywords the same way when building the index, so authoring `docs.example.com` in frontmatter is fine. Hand-editing a `.tsv` to contain a dotted keyword produces a permanently dead entry.
- `BillingModule` in a prompt matches the keyword `billing`, thanks to the CamelCase split.

Each entry fires **once per session**. Once injected it is marked shown and will not repeat — the knowledge is already in context.

## Layers

Each dimension can hold several layers, scanned in order:

| Layer              | Meaning                                   |
| ------------------ | ----------------------------------------- |
| `00-manual/`       | Hand-written. This is where you author.   |
| `10-auto/`         | Generated by your own tooling             |
| `20-grouped/`      | Generated — coarser groupings             |
| `30-crosscutting/` | Generated — themes that span the codebase |

Only `00-manual/` is meant to be edited by hand. The others exist so a generator can maintain bulk coverage without ever touching what a human wrote. If you have no generator, use `00-manual/` alone — the rest can stay empty.

## Configuration

Optional, in `.claude/jit-context/config.env`:

```bash
# Source-root prefix used when turning a vocabulary entry's "## Modules"
# section into path triggers. Default: src/
DYNAMIC_RULES_MODULE_PREFIX="src/"

# Extended regex of keywords too generic to index, however they were authored.
DYNAMIC_RULES_KEYWORD_BLACKLIST="^(count|output|input|name|file|files)$"

# Inject vocabulary on file paths as well as prompts. Off by default: interactive
# sessions already get a vocabulary pass on every prompt, so this would only
# duplicate context. Turn it on for autonomous runs, which send a single prompt
# for the whole run — before they know which part of the codebase they will touch.
DYNAMIC_RULES_VOCAB_PATHS=0
```

## Performance

Every hook is a **single `awk` process**. Frontmatter is parsed at build time into TSV, so the runtime path is a flat file scan with no JSON parsing, no `jq`, and no subprocess per rule. Typical hook time is 30–110 ms, which matters because these run on _every_ prompt and _every_ tool call.

Timings and matches are appended to `.claude/jit-context/.discovery/logs/hooks.log`:

```
[23:48:14.393] pre-tool (Bash) 29ms | 10-auto/billing.md(billing) [shown:11] << src/Billing/Totals.php
```

`(none)` in the match column means nothing fired — useful for finding knowledge gaps.

## Tests

```bash
bash tests/run-all.sh
```

84 assertions across the three hooks, covering matching, normalization, modes, blocking, session-once behaviour and malformed input. No dependencies beyond bash and awk.

## Why not `.claude/rules/`?

Files in `.claude/rules/` auto-load at session start — all of them, every session. Even with `globs` frontmatter for path scoping, the file still loads.

Dynamic rules load only when triggered. A session that never touches PHP never loads the PHP conventions. On a project with a real body of institutional knowledge, that is the difference between a context window mostly full of maybe-relevant documentation and one mostly full of the actual conversation.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

Source-available under the Community License. See [LICENSE](LICENSE).
Use permitted. Modification, redistribution and resale prohibited.
