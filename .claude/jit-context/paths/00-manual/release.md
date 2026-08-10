---
title: The version lives in three files
match: \.claude-plugin/plugin\.json$
---

Bumping the version here is one of three edits. The other two:

- `README.md` — the version badge, near the top
- `CHANGELOG.md` — a new section, not an appended line

Sweep for the **outgoing** value before finishing, with no path filter:

```bash
git grep -n "0\.2\.0"
```

A filtered sweep cannot see a file whose extension you forgot to list — which is exactly how a badge sits stale for a year. A sweep for the incoming value only finds sites already half-bumped, and cannot find a site frozen at some third value: check the badge by eye.

`CHANGELOG.md` says what changed and why the previous design was wrong. It does not sell. `0.2.0` opens with "the documentation described a design that no longer existed" — that is the register.
