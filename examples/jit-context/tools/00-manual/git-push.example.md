---
title: Create a merge request instead of pushing
description: This project reviews through merge requests, so a direct push skips the checks everything else assumes.
tool: Bash
match: ~@invocation git push
mode: remind
---

Pushing straight to the remote skips review. Use the helper, which pushes and opens
the merge request in one step:

```
./scripts/push-and-create-mr.sh
```

Always set a reviewer before pushing.

`~@invocation git push` is the anchor, not the decoration. A bare `match: git push` is a
substring, so it also fires on `git pushd`, on `git stash push` and on any command that
merely mentions the words — copy the macro rather than the two words.
