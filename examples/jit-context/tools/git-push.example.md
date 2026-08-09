---
title: Create a merge request instead of pushing
tool: Bash
match: git push
mode: remind
---

Pushing straight to the remote skips review. Use the helper, which pushes and opens
the merge request in one step:

```
./scripts/push-and-create-mr.sh
```

Always set a reviewer before pushing.
