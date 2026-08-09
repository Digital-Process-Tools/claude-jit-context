---
name: vocabulary
description: Write a jit-context entry that actually works — pick the right dimension, keyword it without noise, and prove it fires. Use when adding or fixing a rule under .claude/jit-context/.
---

# Writing a jit-context entry

**The test:** an entry loads, and the reader still gets it wrong. Then the entry failed. It is a cheat sheet, not a reminder — exact command, exact path, exact pattern. Never "go look it up".

## 1. Pick the dimension first — this is the whole decision

| Dimension | Fires on | Use when |
| --- | --- | --- |
| **paths** | a file path in the tool call | knowledge belongs to a *folder* — "before you touch this, know X" |
| **tools** | tool name + command pattern | you want to intervene *before a specific call runs* |
| **vocabulary** | keywords in the prompt | a *domain* the user names out loud |

**Default to paths.** The folder is the situation. Keywords fire on what someone is talking about; paths fire on what they are touching, and the expensive mistakes happen while touching.

**Measured noise, one session:** `folder` pulled a Google-Drive entry, `time` pulled activity reports, `property` pulled a real-estate client module, `setup` pulled a preproduction monitor. Four injections, four irrelevant, thousands of tokens. Every one was a *keyword* match. Zero path matches misfired.

**Use tools when the fix is an interception**, not information: a `require` that fails the call is worth more than a paragraph that gets skimmed. Evidence: a `| head` reminder existed, in bold, said aloud twice — and was violated three times in six hours. A `mode: block` rule was not.

## 2. Frontmatter

```markdown
---
title: "Short, states the rule not the topic"
match: "presets/watch/"        # path prefix, or ~regex
mode: once, remind
---
```

Tools add `tool:` (may name several, pipe-separated: `Edit|Write|Read`) and optionally `require:` / `forbid:`.

- `once` — fires once per session. Right for orientation.
- `remind` — injects the file.
- `block` — refuses the call. Use when acting wrongly is expensive and the reminder has already failed.
- `require: --limit` — **blocks unless the string is present.** All entries must be present (AND, not OR), so it cannot express "either flag".
- `forbid:` — the list is split on `|`, so **a forbidden string cannot itself contain `|`**. Match the pattern in `match:` instead.

Vocabulary entries use `keywords:` instead of `match:`.

## 3. Keywords, if you must

- **One word that is also ordinary English will fire constantly.** `time`, `file`, `count`, `name`, `output` are already blacklisted; `folder`, `setup`, `property` should have been.
- Prefer multi-word keys and product nouns: `gl-mr`, `changelog fragment`, `poller identity`.
- After building, read the ambiguity report. **A keyword in >5 files means every match loads all of them.** Prune.
- Keywords are normalised — lowercased, anything outside `[a-z0-9 -]` becomes a space. A keyword written `docs.dp.tools` is **dead on arrival**.

## 4. Content rules

- **Tables, commands, `file.py` symbols. Bullets over sentences.** ~40 lines.
- **Cite symbols, not line numbers.** Two line references went stale within one session — one in an issue, one in a brief that sent an agent to the wrong place. `grep the symbol` survives a refactor; `:253` does not.
- Say the **consequence**, not the principle. Not "be careful with check states" — `TIMED_OUT and ACTION_REQUIRED are FAILED, not benign. Name every non-SUCCESS leg before merging.`
- **No "why this matters" paragraphs.** A why-clause only where it changes what someone does.
- If you cannot verify a claim, **leave it out**. Do not write "verify this before citing it" — that is the indirection this format exists to delete.

## 5. Prove it fires

Rebuilding is not evidence. Drive the hook:

```bash
cd <project> && export CLAUDE_PROJECT_DIR="$PWD"
bash <jit>/scripts/rebuild-tsv.sh
bash <jit>/scripts/session-start-hook.sh          # clears `once` markers
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"supertool '"'"'read:tests/x.py'"'"'"}}' \
  | bash <jit>/scripts/pre-path-hook.sh
```

Check **both directions**: a payload that must fire, and one that must stay silent. A rule matching everything is worse than none.

The hook answers `{"decision":"block","reason":...}` or an `additionalContext` payload. If your checker reports nothing for a case you know fires, suspect the checker — that happened three times in one session.

## 6. Before you write one at all

**A rule you invent is worse than no rule**, because it arrives with the same authority as one that cost an agent-run to learn. Two runs of ~200k each were burned on stale premises in a single day.

So: no evidence, no entry. Record the deliberate gap in `00-README.md` (the builder skips it by name) so an absence reads as a decision rather than an oversight.

And when an entry turns out wrong while you are using it, **fix it then** — that is the cheapest moment it will ever have.
