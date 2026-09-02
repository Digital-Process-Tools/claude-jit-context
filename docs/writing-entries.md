# Writing an entry

_Part of [claude-jit-context](../README.md). Full reference, not the getting-started arc._

Every entry is a markdown file with YAML frontmatter, in `00-manual/`. The frontmatter is the only structured part; the body is free-form and goes into context verbatim, unless the project has opted in to [`summary` mode](../README.md#what-a-match-costs).

Two fields apply to every dimension:

| Field         | Required | Meaning                                                                 |
| ------------- | -------- | ----------------------------------------------------------------------- |
| `title`       | no       | One line. Injected on a match under `summary`.                          |
| `description` | **write one** | One line saying what the entry holds. It is what a match injects under `summary`, and what the agent decides on. Without it, a match can only name the entry — and `rebuild-tsv.sh` lists the entries that have none. |
| `inject`      | no       | `summary` or `full`. Overrides the project default for this entry alone. |

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
description: Every command extends CommandBase and returns a typed value.
match: Commands/
---

Every command extends `CommandBase` and implements `declareOptions()`.
Return values are typed — never `void`, because callers assert on the result.
```

`match` is a regex tested against the file path — an **awk ERE, not PCRE**. See
[Patterns are awk, not PCRE](patterns.md#patterns-are-awk-not-pcre) before writing one.

### Tools

```markdown
---
title: Always disable coverage locally
description: Coverage runs take eight minutes locally and CI produces the report anyway.
tool: Bash
match: bin/phpunit
mode: remind
forbid: --coverage-html
---

Coverage runs take 8 minutes locally and are produced by CI anyway.
```

| Field       | Required | Meaning                                                           |
| ----------- | -------- | ----------------------------------------------------------------- |
| `tool`      | yes      | Tool name: `Bash`, `Read`, `Edit`, `Skill`, `Agent`, … — pipe-separated for several, and see [which tools a rule can name](#which-tools-a-rule-can-name) |
| `match`     | yes      | Substring, a regex when prefixed with `~`, or an [invocation macro](#anchoring-on-an-invocation) |
| `mode`      | no       | `remind` (default), `block`, `once` — comma-separated, composable |
| `require`   | no       | Pipe-separated strings that MUST appear, else the call is blocked |
| `forbid`    | no       | Pipe-separated strings that must NOT appear, else blocked         |
| `requires`  | no       | A single binary name this rule cannot enforce without — see [When the rule itself depends on a binary](#when-the-rule-itself-depends-on-a-binary) |

| Mode     | Effect                                                  |
| -------- | ------------------------------------------------------- |
| `remind` | Injects the entry as additional context — the whole body, or its title and `description:` under `summary` |
| `block`  | Rejects the tool call, returning the **whole body** as the reason, whatever the injection mode says |
| `once`   | Injects at most once per session — see below, it does not bound a refusal |

**A `block` rule refuses whether or not its text can be delivered.** Whether the call is stopped is decided by the index row; the entry file decides only what the reason *says*. So an entry that is unreadable, or empty, or missing under a row that still names it, produces a refusal carrying `(the text of this rule was not delivered: …)` in place of the body — never a permitted call. A refusal with a poor reason is still a refusal; a silent allow is not.

That holds for the entry **file name** too, which was the remaining hole (#140). A row whose file column is not a usable name — a `/` or `\` in it, a leading dot, an entry or a layer directory that is a symbolic link, a tree carrying more links than the hook can check — is refused and reported by position, and if it said `block`, the call is refused with it. The rule never gets to read that file, so the reason is the substitute rather than the body; what it does not do is quietly become advisory.

**`once` bounds the injection, never the refusal.** `mode: once, block` refuses **every** matching call of the session, not the first one (#139). The two words are still composable and still mean what they say separately — the entry text is injected at most once, and the call is stopped every time — because an injection is knowledge the agent now has and repeating it is waste, while a refusal is a decision, and a decision that expires was never enforced. The same holds for a `once` rule carrying `require` or `forbid`.

`mode` and `inject` are different axes and it is worth not confusing them: `mode` decides *what the hook does* — remind, refuse, once — and `inject` decides *how much of the entry comes with it*.

### When the rule itself depends on a binary

`mode: block` (and `require:`/`forbid:`) is unconditional by default: it fires whether or not the tool the entry is *about* is installed. That is correct for most rules — a rule about `git` names something the reader can always fix — and wrong for exactly one shape: a rule whose own remedy is a specific binary that this machine might not have. A `block` rule that tells the reader to run a tool that does not resolve on `PATH` is not a guard, it is an outage with an explanation attached (#203).

`requires:` names that binary:

```markdown
---
tool: Read|Edit|Write
match: ~.*
mode: block
requires: supertool
---
```

Probed with `command -v` **in bash, before the hook's one awk process starts** — the awk half of every hook here never shells out, on purpose, so the presence check cannot live inside the row loop that reads everything else off the index. When the named binary is not on `PATH`, `mode: block` (and a `require:`/`forbid:` refusal on the same row) **degrades to advisory**: the call goes through, and the injected text says which binary was missing and that the rule normally refuses:

```text
# JIT Context: supertool-required.md (matched: ~.*)
[jit] This rule would normally refuse this call, but `supertool` was not found on PATH,
so it has degraded to advisory instead of blocking. Install `supertool` to restore
enforcement.
```

Three things worth being exact about:

- **A rule with no `requires:` is unaffected**, whether or not this session's tree names some *other* binary that is missing. `requires:` is opt-in per row, not a global switch.
- **An ordinary `remind` row naming `requires:` is unaffected too.** The degrade is about a check that stops *enforcing* — a row that was never going to block anything has nothing to degrade, and fires exactly as it always did, with the entry text and no mention of a binary.
- **This is one binary, never a list.** `requires: a|b` is read as the single literal string `a|b`, which is not what an author who wrote it meant — a list opens a policy question ("all of them? any of them?") this field does not answer.

### What a tool rule is tested against

Three different subjects, and the difference is what stops a rule about a command from
firing on prose that merely mentions it.

| Field                | Subject                                                            |
| -------------------- | ------------------------------------------------------------------ |
| `match` (substring)  | the **command words** — the command up to the first `;` `&` `\|`, the first `"`, or the first ` --` |
| `~match` (regex)     | the **whole command**, including quoted arguments and later lines   |
| `require` / `forbid` | the **whole command**                                               |

#### Which tools a rule can name

`tool:` accepts any tool name, and the subject above is built from a fixed set of tool
input keys — `command`, `skill`, `file_path`, `pattern` and `subagent_type`. A rule
naming a tool whose call carries none of those has nothing to be matched against, so it
is indexed, counted by every report, and **never consulted**. An `Agent` rule was in
exactly that position until #182; `TodoWrite`, `WebFetch` and any `mcp__…` tool still are.

That set cannot be listed here and kept true — an MCP server defines its own input schema
— so the hook says so instead, on the first dispatch of the session where it happens
(one line, wrapped here):

```text
# JIT Context: 1 tools rule(s) name this tool, but the hook could build no subject to match them against, so they did NOT run
- tools/00-manual row 3
```

An `Agent` rule is matched against `subagent_type` and **not** against `prompt` or
`description`. Those are prose that routinely quotes the very commands deny-list rules
are written about, and the command-words cut above would compare them as an arbitrary
prefix — so `tool: Agent, match: general-purpose` fires on *which agent is dispatched*,
never on what it was asked to do.

So `match: git push` does not fire on `git commit -m "fix git push detection"`, in one
line or twenty — the quote ends the command words, and everything after it is an argument
rather than a command. A `~match` regex does see that text, which is the price of being
able to anchor on a later command: write `~(^|[;&|\n] *)git[[:space:]]+push` rather than
`~git push` when you mean the command and not the words.

**A `block` rule that is not `~`-anchored is advisory against a chained command.** The cut
is at the *first* `;` `&` `|`, so a bare `match:` never sees anything after one, and
`mode: block` on such a row stops the direct call and lets the chained one through:

```text
# a rule with match: rm -rf and mode: block, driven through pre-tool-hook.sh
{"command":"rm -rf /tmp/x"}                    -> blocked
{"command":"git status && rm -rf /tmp/x"}      -> not blocked
```

That is the same truncation that keeps a substring rule off a quoted commit message, and
it is why every `block` rule in this repository is written `~(^|[;&|\n] *)…`. A bare
`match` is fine for a reminder: the cost of one not firing is a reminder nobody got. It is
not fine for a refusal, because the row reads as enforced and is not. `scripts/jit-dry-run.sh` prints an
`ADVISORY` line naming every row in your tree with that shape (#136); it does not change
the exit code, because the rule is narrower than it looks rather than broken.

**The whole-command row of that table holds even when the command words are empty.** A
command that *begins* with one of the cut bytes — `{"command":"; git push"}` — has no
command words at all: the cut takes the lot. Until #186 the hook treated that as nothing
to say and answered `{}` before consulting any rule, so a `~match` rule that would have
matched the whole command never ran, and a `mode: block` one failed open. It runs now, on
the same subject it uses for every other command. A bare `match:` is unchanged and still
sees nothing there, for the same reason it sees nothing after any `;` — that cut is what
keeps it off a quoted commit message.

A command spanning several lines is one string with real newlines in it. `^` anchors that
whole string, not each line, so a rule that must catch the second command needs the
newline in its anchor class — see below.

All four comparisons are **accent-insensitive**, on both sides and by the same rule the
vocabulary dimension uses: Latin-1 accents on the command and on the term both fold to the
ASCII base before either is compared. So `forbid: clé-privée` refuses `--key CLÉ-PRIVÉE`,
and `require: validé` is satisfied by `VALIDÉ`. Write the accented spelling — it is the one
your team reads; the unaccented spelling of the same word matches too, in both directions.
The fold drops the accent, never the letter, so `cl-prive` matches nothing. It is a
**substring** test, though, not the space-bounded one the vocabulary dimension uses, so a
prefix of the term still matches — `cle-prive` does fire the `clé-privée` rule.

`match` and the `require`/`forbid` terms are also **case-insensitive**. A `~match` regex is
not: the command is lowercased before the pattern is applied and the pattern is not, which
is unchanged and means a pattern carrying an ASCII capital matches nothing. Write `~git`,
never `~Git`. Accents in a pattern do fold with the subject, so an accented character class
keeps working. Drive it yourself:

```bash
printf '{"tool_name":"Bash","tool_input":{"command":"deploy --key CLÉ-PRIVÉE"}}' \
  | CLAUDE_PROJECT_DIR=. bash scripts/pre-tool-hook.sh
```

### Anchoring on an invocation

That anchor is the load-bearing part of a rule, and it is the part nobody can verify by
reading. Four of ours were wrong: an alternative that could never fire, `git stash push`
blocked by a rule written for `git push`, a rule shipped with no anchor at all, and this
repository's own rule matching a temporary directory. So the two shapes that keep being
hand-written are named instead of retyped:

```markdown
---
tool: Bash
match: ~@invocation git push
mode: block
---
```

| Macro                            | Matches                                | Does not match       |
| -------------------------------- | -------------------------------------- | -------------------- |
| `~@invocation git push`          | `git push`, `git -C /tmp push`, `rtk git push`, `cd x && git push` | `git stash push`, `git pushall`, `git commit -m "fix git push"` |
| `~@invocation-quoted-arg gh`     | `gh 'pr list' \| head`, `gh "pr list"`  | `gh \| tail`, `gh pr list`, `cat /opt/gh 'x'` |

`@invocation` is the command word at invocation position — optionally behind a wrapper
(`rtk`, `command`, `env`, `sudo`) or an environment assignment, and with only
**option-shaped** tokens between the words. That last part is the difference between the
two columns: a subcommand is not an option, which is what the widely copied
`([^;&|\n]*[[:space:]])?` gets wrong. `@invocation-quoted-arg` is the same, followed by a
quoted argument before any pipe.

The macro is expanded into a plain awk ERE by `rebuild-tsv.sh`, so the index format does
not change and neither does anything a hook reads. A macro name it does not know is
**refused and named** at build time, and the row is written through unexpanded so the hook
refuses it again by name rather than compiling a literal that matches nothing.

Only the `tools` dimension has these — a `paths` `match` is tested against a file path, so
an invocation macro there is refused.
