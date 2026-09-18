---
title: "supertool edit/paste: a trailing quote glued to the TOML delimiter is silently dropped"
description: "If a TOML old/new/content field's own last character is a literal quote (or backslash) on the same line as the closing triple-quote delimiter, the parser reads it as part of the delimiter and drops it -- put that trailing character on its own line."
tool: Bash
match: ~@invocation-quoted-arg supertool
mode: once
---

`supertool edit:@-` / `paste:@-` read a TOML literal string from stdin. TOML's multi-line
literal-string parser takes the FIRST run of three consecutive quote characters as the closing
delimiter. If your `old`/`new`/`content` field's own last character is a literal quote, and it
sits on the same line as the closing `"""`, that line reads as content-quote immediately
followed by the three delimiter quotes — the parser's first "three in a row" reading consumes
the content's own quote along with the real delimiter, silently dropping a byte the target file
actually needs (most often a bash closing quote) from both `old` and `new` (#397).

- `old` can still match — as a prefix of the real content minus its last byte — so the edit
  succeeds at the anchor stage and only fails later, off in whatever checks the result
  (`bash-check`, a syntax check), with a message that gives no hint the dropped byte was
  self-inflicted.
- **Fix: put the content's own trailing quote on its OWN line**, separated by a newline from the
  closing delimiter line. A trailing line-continuation backslash is the same class, but
  supertool's own payload linter already refuses that one outright with a clear message.
- Prose that spells out the delimiter itself (three quote characters, typed literally) inside a
  literal block closes it early too — describe it in words instead of typing it.
