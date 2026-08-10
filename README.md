# claude-jit-context

![claude-jit-context — know more, carry less](docs/jit-context.png)

[![Tests](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml/badge.svg)](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml)
[![Shell](https://img.shields.io/badge/bash-3.2%2B-blue)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/tested%20on-Linux%20%7C%20macOS%20%7C%20Windows-blue)](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Community-brightgreen)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.0-orange)](.claude-plugin/plugin.json)

**Your agent should know what your team knows.**

Every team has a vocabulary. *Billing* means the totals are computed and never stored. *The deploy* means the one where the migration runs first. *That flaky test* means the one that fails on Tuesdays, for a reason three people know and nobody wrote down.

Claude Code does not have your vocabulary. So you re-explain it — every session, to every agent, forever.

The usual fix is `.claude/rules/`, or a `CLAUDE.md` that keeps growing. It works right up until it does not: every file loads at session start, every session, whether or not that session goes anywhere near the code it describes. So you keep the rules file small. So the vocabulary stays in people's heads.

claude-jit-context takes the ceiling off. Knowledge moves behind pattern matching, and arrives at the moment it applies: the migration note loads when someone opens a migration. The billing gotcha loads when the prompt says billing. A session that never touches PHP never pays for the PHP conventions.

**Know more. Carry less.** Everything else that saves context makes the agent dumber — trim the rules, drop the conventions, summarize the docs. This is the one lever that cuts what is *resident* without cutting what is *known*.

## The receipt

The project this was extracted from runs **1,000 entries — 2.58 MB of markdown**, on the order of 600,000 tokens. As `.claude/rules/` that is not expensive, it is impossible: it does not fit in any context window that exists. A handful of entries fire in a given session. The rest cost nothing, and are still there the moment they are relevant.

That is the actual offer. Not a percentage off your context budget — a body of institutional knowledge with no ceiling, written down once, and read by every session and every developer who joins.

Nothing loads speculatively. Nothing is resident.

## Why this exists

A friend told Florian that `.claude/rules/` saves tokens — especially on something the size of DVSI, which is exactly the kind of project the feature seems written for. So he spent two hours moving our conventions into rule files, each scoped with a `paths:` glob, expecting sessions to get lighter.

Then he ran `/context`. Everything was loaded. Every rule file, in a session that had touched almost none of the code they described.

We spent a while assuming we had misconfigured it. We had not — as far as we could measure at the time, the scoping did not gate the load at all.

The interesting part came after. If Claude Code can inject context at the moment a file is opened, why should the trigger be a file? Why not the word `XSD` when someone types it? Why not the moment a test command is about to run without `--no-coverage`?

Those two questions are the vocabulary and tool dimensions. The whole plugin is the answer to them.

## Five pillars

**1. Zero until triggered.** An entry costs nothing to own. That is the whole design: the price of writing something down stops being a reason not to write it down, so the corpus grows to the size of what your team actually knows rather than the size of what you can afford to keep loaded.

**2. Three ways to be needed.** Knowledge attaches to a keyword in the prompt, a file path being touched, or a tool about to run. Pick by asking *when* the reader needs it. Most notes belong to a folder, not to a word — the expensive mistakes happen while touching, not while talking.

**3. It can say no.** The tool dimension does not only inform, it **blocks** — refusing the call and returning the reason. A `require:` that fails the command is worth more than a paragraph that gets skimmed. A rule that is merely bold has already been ignored.

**4. One `awk`, 30–110 ms.** Frontmatter is compiled to a TSV index at build time, so the runtime is a flat file scan. No `jq`, no Python, no Node. This matters because it runs on *every* prompt and *every* tool call — the thing that fires constantly must cost nothing.

**5. Hand-written and generated, side by side.** `00-manual/` is yours. The other layers belong to generators, which can maintain bulk coverage across a large codebase without ever overwriting a line a human wrote.

## The signal

You will feel it before you can name it: **the agent is rediscovering something it should already know.**

It greps for a file it found last week. It re-derives a convention you have explained four times. It proposes the fix that was already tried and reverted, for a reason nobody wrote down. Every one of those is the same event — knowledge that exists on your team, and does not exist where the agent can reach it.

That moment is the trigger. Do not re-explain it in the chat, where it dies at the end of the session. Write the entry:

```markdown
---
title: Billing amounts
description: How invoice totals are computed, and why the entity getter lies.
keywords: billing, invoice, amount, vat, total
---

Totals are **not** stored. `getAmountVatOut()` is recomputed from line items on
every call. Writing to `amount_vat_out` directly appears to work and is silently
discarded on the next read.
```

```bash
bash scripts/rebuild-tsv.sh
```

The search you just paid for is the reason the entry is worth writing — and the only moment you will ever know it well enough to write it in four lines. From then on it arrives on its own, in every session, for everyone, and nobody spends that search again.

A codebase accumulates this way faster than anyone expects. That is why pillar one matters: if entries cost context to own, you ration them, and the rationing is what keeps your team's knowledge trapped in people's heads.

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

Bash, `awk`, `perl` (used only for millisecond timestamps). **No `jq`, no Python, no Node.**

Linux, macOS and Windows. The suite runs on all three in CI — including macOS's bash 3.2 and Windows under Git Bash. On Windows the hooks need a `bash` on `PATH`, which Git Bash provides; that is the same requirement every hook-based plugin in this family has.

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

`match` is a regex tested against the file path — an **awk ERE, not PCRE**. See
[Patterns are awk, not PCRE](#patterns-are-awk-not-pcre) before writing one.

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

### Patterns are awk, not PCRE

Every regex — a `paths` `match`, and a `tools` `match` prefixed with `~` — is compiled by
**awk**, so it is a POSIX ERE. PCRE shorthand classes do not exist there, and the failure
is silent: measured on `awk version 20200816`, `~gh\s+pr` compiles to `ghs+pr` and matches
nothing at all, while awk exits 0. Nothing about the rule looks wrong afterwards.

| Do not write | Write instead    |
| ------------ | ---------------- |
| `\s` `\S`    | `[[:space:]]`    |
| `\d` `\D`    | `[0-9]`          |
| `\w` `\W`    | `[A-Za-z0-9_]`   |
| `\b` `\B`    | anchor explicitly, e.g. `(^\|[;&\|\n] *)` |

`\n` is the one escape that survives, and rules need it: `^` anchors the whole command
string rather than each line, so a rule meant to catch a command on line three of a
heredoc must anchor on `(^|[;&|\n] *)`.

**A pattern the matcher cannot honour is refused at load and reported** — the row is
skipped, every other rule in the file keeps working, and the hook injects a one-line
notice naming the rule and the construct, once per session. Two things this replaces:
a rule that read as enforced for as long as it existed, and a single malformed pattern
(`~a[b` is a fatal awk error) that silenced every rule in its index at once.

### Compatibility — tools that touch files through `Bash`

Path rules read `file_path` from `Read`/`Edit`/`Write`/`Glob`/`Grep`. Anything that reaches a file some other way does not carry that field, and a naive implementation would stop matching the moment a session used one — every path rule you wrote would go quiet, with no error and nothing in the log to explain it.

So `Bash` commands are scanned too: **any path-like token (anything containing `/`) counts as a path being touched.** That covers `sed -i src/Billing/Totals.php`, a test runner pointed at a directory, a shell loop over a glob, or a batching wrapper such as [supertool](https://github.com/Digital-Process-Tools/claude-supertool), whose quoted arguments are unpacked so that

```bash
./supertool 'read:src/Billing/Totals.php' 'grep:getAmount:src/Billing/:10'
```

still fires the rules for `src/Billing/`.

Commands with no path in them match nothing — deliberately, so that a stray word in a commit message cannot drag an unrelated entry into context.

## Rebuild after every edit

Entries do nothing until they are indexed:

```bash
bash .claude/claude-jit-context/scripts/rebuild-tsv.sh
```

This parses the frontmatter of every `.md` file into `00-index.tsv` files, which is what the hooks actually read. It also prints an **ambiguity report** — keywords appearing in more than five entries. Those are worth pruning: every match loads the whole entry, so a keyword like `user` in twelve files means one stray mention drags twelve files into context.

### Verify an entry actually fires

An entry that never fires looks exactly like work that was done.

```bash
bash scripts/jit-dry-run.sh                                    # lint every pattern
bash scripts/jit-dry-run.sh --prompt "how do invoice totals work"
bash scripts/jit-dry-run.sh --tool Bash --command "git push origin main"
bash scripts/jit-dry-run.sh --file src/Billing/Total.php
```

It prints a verdict per rule and which rule fired for the sample call, and exits **1**
when a pattern cannot be honoured, **2** when it could not evaluate the tree at all —
no index, no `awk`. A tree it could not read never reports as clean.

**It reads the tree you are standing in**, or `--base DIR`. That matters because the
hooks resolve rules against `$CLAUDE_PROJECT_DIR` and never the current directory, so a
git worktree, a checkout under review, or a plugin being developed cannot load or test
its own rules from a session rooted elsewhere — with nothing to say so.

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

| Layer              | Meaning                                                     |
| ------------------ | ----------------------------------------------------------- |
| `00-manual/`       | Hand-written. This is where you author, and what is indexed. |
| `10-auto/`         | Reserved for a generator you supply                         |
| `20-grouped/`      | Reserved — coarser groupings                                |
| `30-crosscutting/` | Reserved — themes that span the codebase                    |

**Most projects need only `00-manual/`, and that is the whole feature.** The other three are extension points, not shipped functionality — worth understanding before you plan around them:

`rebuild-tsv.sh` indexes `00-manual/` and nothing else. The hooks, however, scan all four layers in the order above. So a generated layer works only if the generator writes its own `00-index.tsv` in the same format; creating `20-grouped/*.md` and running the rebuild produces silence, because nothing indexed it.

No generator ships with this plugin. The layers exist so that bulk-generated coverage can sit beside hand-written entries without either overwriting the other — the arrangement a large codebase ends up wanting. If you are not generating entries, leave the three directories absent.

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

Files in `.claude/rules/` auto-load at session start — all of them, every session. When we measured this on a large codebase in early 2026, `globs` frontmatter did not change that: `/context` showed every rule file resident, whatever its scope. Claude Code moves quickly, so check it yourself with `/context` before taking our word for it — but that measurement is why this plugin exists.

On a project with a real body of institutional knowledge, that is the difference between a context window mostly full of maybe-relevant documentation and one mostly full of the actual conversation.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

Source-available under the Community License. See [LICENSE](LICENSE).
Use permitted. Modification, redistribution and resale prohibited.
