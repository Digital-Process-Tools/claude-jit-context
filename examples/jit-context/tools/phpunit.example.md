---
title: Local test runs must skip coverage
tool: Bash
match: bin/phpunit
mode: remind
require: --no-coverage
forbid: --coverage-html
---

Coverage instrumentation makes a local run take roughly eight minutes instead of
forty seconds, and CI produces the report anyway.

`require` blocks the call when `--no-coverage` is missing; `forbid` blocks it when
`--coverage-html` is present. The body you are reading is returned as the reason.
