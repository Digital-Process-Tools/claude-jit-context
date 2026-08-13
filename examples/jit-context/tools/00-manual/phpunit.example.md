---
title: Local test runs must skip coverage
tool: Bash
match: ~(^|[;&|\n] *)([^;&|[:space:]]*/)?bin/phpunit($|[[:space:];&|])
mode: remind
require: --no-coverage
---

Coverage instrumentation makes a local run take roughly eight minutes instead of
forty seconds, and CI produces the report anyway.

The anchor is spelled out rather than macroed because the command is a **path**.
`~@invocation bin/phpunit` anchors on a command word and would miss `./bin/phpunit`
and `vendor/bin/phpunit`, which is how most people spell it; the leading
`([^;&|[:space:]]*/)?` is that directory prefix. A bare `match: bin/phpunit` is worse
in the other direction — it is a substring, so `cat bin/phpunit-report.txt` came back
`BLOCKED: Missing required: --no-coverage`, a refusal of a command that runs no tests.

`require` blocks the call when `--no-coverage` is missing, and the body you are reading
is returned as the reason. `mode: remind` is not a contradiction: it says the rule does
not refuse every `bin/phpunit` call outright — `require` and `forbid` are what refuse,
and they are checked whatever the mode says.

This entry deliberately carries no `forbid`. `require` is evaluated first and
short-circuits, so a `forbid: --coverage-html` here could only ever speak on
`bin/phpunit --no-coverage --coverage-html` — a command that contradicts itself and that
nobody types. Put a `forbid` on its own axis instead; `git-commit.example.md` does.
