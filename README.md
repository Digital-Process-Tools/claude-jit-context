# claude-jit-context

![claude-jit-context — know more, carry less](docs/jit-context.png)

[![Tests](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml/badge.svg)](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml)
[![Shell](https://img.shields.io/badge/bash-3.2%2B-blue)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/tested%20on-Linux%20%7C%20macOS%20%7C%20Windows-blue)](https://github.com/Digital-Process-Tools/claude-jit-context/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Community-brightgreen)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.6.0-orange)](.claude-plugin/plugin.json)

**Your agent should know what your team knows.**

Every team has a vocabulary. *Billing* means the totals are computed and never stored. *The deploy* means the one where the migration runs first. *That flaky test* means the one that fails on Tuesdays, for a reason three people know and nobody wrote down.

Claude Code does not have your vocabulary. So you re-explain it — every session, to every agent, forever.

The usual fix is `.claude/rules/`, or a `CLAUDE.md` that keeps growing. It works right up until it does not: every file loads at session start, every session, whether or not that session goes anywhere near the code it describes. So you keep the rules file small. So the vocabulary stays in people's heads.

claude-jit-context takes the ceiling off. Knowledge moves behind pattern matching, and arrives at the moment it applies: the migration note loads when someone opens a migration. The billing gotcha loads when the prompt says billing. A session that never touches PHP never pays for the PHP conventions.

**Know more. Carry less.** Everything else that saves context makes the agent dumber — trim the rules, drop the conventions, summarize the docs. This is the one lever that cuts what is *resident* without cutting what is *known*.

## From the same workshop

Four plugins, one team, each does one thing. This one and three siblings:

- [claude-remember](https://github.com/Digital-Process-Tools/claude-remember): memory across sessions. Saves, compresses through Haiku, reloads at the next start.
- [claude-supertool](https://github.com/Digital-Process-Tools/claude-supertool): batched file and tracker ops. One call instead of seven, and a refusal instead of a wrong answer.
- [claude-oss](https://github.com/Digital-Process-Tools/claude-oss): the maintainer loop that runs these four repos. Triage, build, review, merge, release.

All four install from one marketplace: `/plugin marketplace add Digital-Process-Tools/claude-marketplace`.

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
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/claude-jit-context/scripts/post-tool-hook.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/claude-jit-context/scripts/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

### Requirements

Bash, `awk`, `perl` (used only for millisecond timestamps) and `mktemp` (one scratch file per hook fire, created with an unpredictable name so nothing outside your project can be pointed at). **No `jq`, no Python, no Node.**

`mktemp` is the only soft one: a system without it, or with no writable `$TMPDIR`, loses the hook log and the once-per-session dedup and keeps everything else — rules still match, entries still inject, the hook still exits `0`.

Linux, macOS and Windows. The suite runs on all three in CI — including macOS's bash 3.2 and Windows under Git Bash. On Windows the hooks need a `bash` on `PATH`, which Git Bash provides; that is the same requirement every hook-based plugin in this family has.

## Your first entry, in one command

A fresh install has nothing to match, so nothing happens — and the first thing anyone
wants to know is how to make something happen. Ask the plugin:

```bash
/jit-context:init
```

The recommended install is the marketplace, and after that install this is the only path
that exists: `$CLAUDE_PLUGIN_ROOT` is not a variable your own shell has, and the
alternative — finding `jit-init.sh` under `~/.claude/plugins/cache/...` — changes on every
update (#202). The raw script still works too: `bash scripts/jit-init.sh` from a clone, or
`bash .claude/claude-jit-context/scripts/jit-init.sh` after the manual install above.

It creates `vocabulary/`, `paths/` and `tools/` under `.claude/jit-context/`, drops one
entry that answers _"how do I write one of these?"_, and builds the index so that entry is
live rather than sitting there inert. Type "how do I write a jit entry" in your next prompt
and it arrives — the documentation delivered by the mechanism it documents.

The file is yours from that moment. Edit it, delete it, or write your own beside it. A
second run **refuses rather than overwrites**: a copy you have edited is not ours to
replace, and that refusal exits `1` and says which file it left alone — `/jit-context:init`
relays that refusal verbatim.

Nothing else is installed and no rule is read from outside your project. Everything the
hooks ever match lives in your repository, where you can read it.

It seeds the project you are standing in; `--base DIR` seeds another —
`/jit-context:init --base ~/work/other-project/.claude/jit-context` — and refuses any path
that is not a `<project>/.claude/jit-context`, because seeding anywhere else writes entries
no hook will ever load.

`--base` is resolved before anything is written, so every path it prints is the physical
location of the files — a symbolic link above `.claude` is followed and reported at its
target, and `..` is folded away. A link at or below `.claude` is refused rather than
followed: the hooks will not read an entry through one, so seeding past it would leave a
rule that can never fire.

### Four worked entries, ready to copy

`examples/jit-context/` carries five entries — one `paths/`, one `vocabulary/` and three
`tools/`, one each for `remind`, `require` and `forbid` — in the exact layout the hooks
read. Copy the tree into your project and rebuild:

```bash
cp -R examples/jit-context/. .claude/jit-context/
bash scripts/rebuild-tsv.sh
bash scripts/jit-dry-run.sh --base "$PWD/.claude/jit-context" --command "git push origin main"
```

They are samples with real frontmatter, so treat them as a starting point and not as
rules about your project — but every one of them is driven in both directions by
`tests/test-shipped-examples.sh`, on the same hooks your session runs. The `--base` there
is absolute on purpose: a relative one is resolved against the dry-run's own working
directory, which prints `SKIPPED` for every sample and still exits `0`.

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

## What a match costs

A match injects the entry body, whole. That is the default and it is what this has always done.

It is also the thing worth thinking about, because the cost is asymmetric: a miss costs nothing, and a false positive costs the whole entry. One session about token tooling pulled a 14.9 KB tag-hierarchy reference on the word `tag`, in a conversation about YAML metadata. The match was correct on its own terms — the word was there — and it was 15,000 tokens wrong.

**`summary` mode** is the answer to that. A match then injects the entry's **title and its `description:`** — roughly 20 tokens — and the agent reads the file if it wants the rest. Being wrong gets cheap, rather than the matcher getting cleverer:

```
# Vocabulary: tag-system-gotchas.md (matched: tag)
Tag hierarchy
How tags nest, and why tag_relation rows are written in pairs.
[jit] Summary only -- read .claude/jit-context/vocabulary/00-manual/tag-system-gotchas.md for the entry.
```

```bash
# .claude/jit-context/config.env
JIT_CONTEXT_INJECT=summary
```

**It is not the default, and the reason is upgrade safety rather than doubt about the trade.** A project that installed this before the mode existed has entries that arrive whole and agents that behave as though they will. Flipping that under them, on an upgrade nobody read the notes for, takes away knowledge the project already relies on and does it silently — which is the exact failure this plugin exists to name, committed by the plugin. So `full` is what you get if you say nothing, and `summary` is where you go once you have looked at what a match costs on your tree and decided.

That last part is meant to be a decision and not a slogan, so the numbers are printed for you. `rebuild-tsv.sh` prices one match on your own corpus:

```
=== What a match costs on this tree ===
Project default: JIT_CONTEXT_INJECT=full

Every match injects the whole entry. Per match, on this tree:

  largest    6105 bytes  ->    311 summarised   .claude/jit-context/paths/00-manual/hooks.md
  median     3718 bytes  ->    310 summarised   .claude/jit-context/paths/00-manual/tests.md

7 entr(ies) indexed.

Every entry carries a description:, so this tree can move to summary whenever
you decide the trade is worth it: JIT_CONTEXT_INJECT=summary in config.env.
```

It prices **one match**, never a corpus total. Nothing here is ever resident, so "summary mode would save 2.4 MB" would be a true sentence about a quantity that has never been in a context window. How often each entry actually fires is in `hooks.log`, which is the only place that number exists.

An entry with no `description:` cannot be summarised into anything but its own name, so those are named as the work between you and being able to flip. `jit-dry-run.sh` carries the other half — what a specific call cost, measured rather than estimated:

```
  pre-path-hook.sh     hooks.md(WHOLE BODY) [6245 bytes injected]
  pre-path-hook.sh     hooks.md(summary) [385 bytes injected]
```

**The project chooses, not the entry's author.** The default lives in `config.env`, set by whoever pays for the context window; an individual entry overrides it with `inject: summary` or `inject: full`. That asymmetry is deliberate — an author who marks their own entry critical is marking it against a count somebody reads at build time.

Four rules that are not settings:

- **An entry with no `description:` is named and not injected**, under `summary`. Nothing is auto-derived — a generated summary of a wrong entry is a confident wrong summary, and it removes the moment you would have noticed. What you get instead is the entry's name and a line saying it has no description.
- **A tools rule that *refuses* a call injects its whole body**, whatever the mode says. The call is already stopped; there is no next turn in which to spend a cheaper answer.
- **An entry with no frontmatter at all injects its body**, in every mode. It has no `description:` — and no `keywords:` or `match:` either, so `rebuild-tsv.sh` could not have indexed it. Its body is the entry.
- **The `(matched: …)` header is inside the budget, not beside it.** Wherever a tools match injects something *other* than an entry body — a summary, the substitute for an entry file that could not be read, or an entry whose file holds nothing but blank lines — both index columns that line quotes are clipped and the cut is marked `[clipped]`: the pattern at 160 bytes, the file name at 255 (#146, #165). A 60 KB `match:` pattern cannot reopen the cost `summary` was added to close, and cannot ride in on a row whose file is missing, or on one with nothing under its header to justify quoting it whole. The header is echoed whole in exactly two places, and both deliver the whole entry beneath it: a `full` entry that actually had a body, and a refusal.

Any other value — including `gated`, a third mode that is designed and deliberately **not built**, held until there is data on how often the pull step is actually taken — falls back to the default, which stands, and is **named** rather than silently ignored. The two settings say so through different channels, because they are different mistakes:

- A bad `JIT_CONTEXT_INJECT` in `config.env` is a standing fact about the project, so it is refused and named in `hooks.log` and once per session in context.
- A bad `inject:` in one entry is a property of that entry, so it is named inside what **that entry** injects, every time it fires and in either mode. It costs 94 bytes, it rides an injection that is already deduped per session, and it stops the moment you fix the line. Under `full` this said nothing at all until #118 — a mistyped `inject:` produced an entry that behaved exactly as though the line were never written, on the path every unconfigured project is on.

The loss `summary` buys with is real and worth stating: the pull is a soft rule, and an agent under momentum will sometimes skip an entry it needed. Whether that happens is measurable — reading an entry is a tool call, so it lands in `hooks.log` beside everything else.

## Writing an entry

Every entry is a markdown file with YAML frontmatter, in `00-manual/`. The frontmatter is the only structured part; the body is free-form and goes into context verbatim, unless the project has opted in to [`summary` mode](#what-a-match-costs).

Two fields apply to every dimension:

| Field         | Required | Meaning                                                                 |
| ------------- | -------- | ----------------------------------------------------------------------- |
| `title`       | no       | One line. Injected on a match under `summary`.                          |
| `description` | **write one** | One line saying what the entry holds. It is what a match injects under `summary`, and what the agent decides on. Without it, a match can only name the entry — and `rebuild-tsv.sh` lists the entries that have none. |
| `inject`      | no       | `summary` or `full`. Overrides the project default for this entry alone. |

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

That is a vocabulary entry, matched on a keyword in the prompt. A `paths/` entry matches a file path instead, and a `tools/` entry matches — and can refuse — a command. Every field, every mode, invocation anchoring and the awk-vs-PCRE pattern rules are in [`docs/writing-entries.md`](docs/writing-entries.md) and [`docs/patterns.md`](docs/patterns.md).

## Rebuild after every edit

Entries do nothing until they are indexed:

```bash
bash scripts/rebuild-tsv.sh
```

The hooks read `00-index.tsv`, never your markdown, so an edited entry that has not been rebuilt is **inert** — nothing errors, nothing warns, the rule simply never fires. Run it after every frontmatter edit; a body-only edit does not need it, since the body is read from the file at fire time. [`docs/diagnostics.md`](docs/diagnostics.md) covers the ambiguity report, the exit codes, and the tools — `jit-doctor.sh`, `jit-match.sh`, `jit-dry-run.sh`, `jit-misses.sh` — that answer "is any of this actually running".

## Further reading

Everything past the getting-started arc above moved to `docs/` rather than being deleted:

- [`docs/writing-entries.md`](docs/writing-entries.md) — every field, every mode, `requires:`, which tools a rule can name, anchoring on an invocation
- [`docs/patterns.md`](docs/patterns.md) — awk vs PCRE, and the tools-that-touch-files-through-`Bash` compatibility layer
- [`docs/keyword-matching.md`](docs/keyword-matching.md) — normalization, accent folding, the generic-keyword fallback, once-per-session dedup
- [`docs/layers.md`](docs/layers.md) — `00-manual/`, `10-auto/`, and writing a layer of your own
- [`docs/configuration.md`](docs/configuration.md) — `config.env`
- [`docs/performance.md`](docs/performance.md) — hook timing, `hooks.log`, the log cap
- [`docs/diagnostics.md`](docs/diagnostics.md) — `jit-doctor.sh`, `jit-match.sh`, `jit-dry-run.sh`, `jit-misses.sh`, and the ambiguity report

## Tests

```bash
bash tests/run-all.sh
```

One suite per hook, plus the dry-run, the miss report, and what a hostile project directory can make the hooks read, write or say — matching, normalization, modes, blocking, session-once behaviour and malformed input. Engine-sensitive assertions run once per `awk` on the machine. No dependencies beyond bash, `awk` and `perl`.

Two suites are the exception, and they are about this repository rather than the hooks. One is release tooling: `test-changelog-fragment-refs.sh` checks that nothing outside `changelog.d/` names a fragment the next tag will delete. The other is prose: `test-line-citations.sh` refuses a comment — or, since #198, a line of markdown anywhere in the repository — that cites a line *number* in another file, because such a pointer is wrong on the next change that inserts a line above it and a rotted citation reads exactly like a live one. Both are file reads — no `python3`, no `markdown-it-py` — so `run-all.sh` still needs nothing but bash, `awk` and `perl`. The assembler that first suite is about is `.oss/assemble_changelog.py`, which is vendored rather than maintained here and has its own suite upstream; the `oss changelog` workflow installs the parser and drives it on every pull request.

The assertion count is deliberately not written here. It was wrong three times in one hour on the day this sentence was rewritten: every branch that adds a test invalidates it, and nothing fails when it drifts — the same defect `tests/test-version-sites.sh` exists to catch for the version number. Run the suite; it prints the number it actually has.

The two containment suites build their fixtures with `ln -s`, and a platform that does not create symbolic links cannot construct the attack they exist to refuse — Git Bash copies the target instead unless `MSYS=winsymlinks:nativestrict` is set and the process may create links. Those suites **probe for that first and skip loudly rather than pass**, and `run-all.sh` reports a skipped suite as neither a pass nor a failure. A suite that reported success where it could not test anything would be the exact defect this plugin exists to describe.

CI sets `MSYS=winsymlinks:nativestrict` — meaningful only to Git Bash, so only the Windows leg changes — and declares the requirement with `JIT_TESTS_REQUIRE_SYMLINKS=1` on all three legs. That second variable separates two things a bare skip cannot tell apart: a platform that never had symbolic links, which skips, and an environment configured to have them that did not get them, which **fails** — a skip renders green, so a setting that quietly stopped applying would restore the hole without anyone noticing. Set it yourself if you want the same guarantee locally; leave it unset and the honest skip is what you get.

## Why not `.claude/rules/`?

Files in `.claude/rules/` auto-load at session start — all of them, every session. When we measured this on a large codebase in early 2026, `globs` frontmatter did not change that: `/context` showed every rule file resident, whatever its scope. Claude Code moves quickly, so check it yourself with `/context` before taking our word for it — but that measurement is why this plugin exists.

On a project with a real body of institutional knowledge, that is the difference between a context window mostly full of maybe-relevant documentation and one mostly full of the actual conversation.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). It is assembled at release from one fragment per change —
contributors add `changelog.d/<issue>.<section>.md` and never edit the file itself. The
convention is in [changelog.d/README.md](changelog.d/README.md).

That assembler is Python and lives under `.github/`, which is **not** the runtime this page
promises: nothing in `.github/` ships inside the plugin, and the six hooks that run in your
session are still `bash` + `awk` + `perl` with no install step.

## License

Source-available under the Community License. See [LICENSE](LICENSE).
Use permitted. Modification, redistribution and resale prohibited.

Third-party licence terms for data bundled in this repository (`data/generic-words.txt`)
are reproduced separately in [NOTICE](NOTICE).
