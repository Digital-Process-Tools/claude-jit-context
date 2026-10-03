---
title: How to write a jit-context entry
description: The three dimensions, the frontmatter fields, and why an unindexed entry never fires.
keywords: jit entry, jit context, jit-context, jit-init, 00-manual, rebuild-tsv, frontmatter keywords
---

`jit-init` put this file here. It is yours — edit it, or delete it.

Three dimensions, one trigger each. Pick by asking _when_ the reader needs it.

| Directory     | Fires on                              | Key frontmatter        |
| ------------- | ------------------------------------- | ---------------------- |
| `vocabulary/` | a keyword in the prompt               | `keywords:`            |
| `paths/`      | a file path being touched             | `match:`               |
| `tools/`      | a tool about to run                   | `tool:` + `match:`     |

Tools is the only dimension that can refuse a call — `mode: block`, with `require:` and
`forbid:` naming what the command must and must not contain. The other two only inject.

An entry is markdown with YAML frontmatter, in `<dimension>/00-manual/`. `title:` and
`description:` are prose; the body below the frontmatter is free-form and goes into
context verbatim. Then, without exception:

```bash
bash rebuild-tsv.sh
```

**The hooks never read your markdown. They read the `00-index.tsv` that rebuild writes.**
A frontmatter edit you have not rebuilt is inert, and inert in silence: nothing errors,
nothing warns, the rule simply never fires — which looks exactly like a rule that runs and
never matches. Body edits are read at fire time and need no rebuild.

So prove it fires, in both directions, before you trust it:

```bash
bash jit-dry-run.sh --prompt "how do I write a jit entry"
```

Two things that cost people a day:

- `match:` is an **awk ERE, not PCRE**. `\s`, `\d` and `\w` compile to the bare letter and
  match nothing; `\b` is a backspace character. Write `[[:space:]]`, `[0-9]`, `[A-Za-z0-9_]`.
- One ordinary English word as a keyword fires on every session that happens to mention it.
  Prefer product nouns and multi-word keys — this entry keys on `jit entry`, never on
  `vocabulary`.
