---
title: Never skip the pre-commit hooks
tool: Bash
match: ~@invocation git commit
mode: remind
forbid: --no-verify
---

The pre-commit hooks are the only place the formatter and the secret scan run before a
branch leaves the machine. `--no-verify` skips both, and the commit that skipped them is
indistinguishable from one that passed by the time anyone reads the branch.

`forbid` blocks the call when the flag is present and returns this body as the reason.
Nothing here is `require`d, so the flag is the only thing this rule has an opinion about
and an ordinary `git commit -m ...` passes untouched.
