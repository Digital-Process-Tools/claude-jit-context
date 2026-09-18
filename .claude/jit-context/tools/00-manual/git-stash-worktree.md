---
title: "git stash pop is repo-global, not worktree-scoped"
description: "A worktree shares one .git; git stash pop applies whatever is on top of the repo-wide stash stack, not what the immediately-preceding push in this worktree did or didn't create."
tool: Bash
match: ~@invocation git stash pop
mode: remind
---

`.git` is shared across every `git worktree add` tree of the same clone, and so is the stash
list. `git stash push -- <file>` reporting "No local changes to save" means nothing was pushed
by *this* invocation — it says nothing about what is already on the stack. The following
`git stash pop` is not scoped to what that push did or didn't create: it pops whatever
`stash@{0}` is, repo-wide, which can be a leftover from an unrelated branch sitting in a
sibling worktree (#388).

- **Check first: `git stash list` before any `pop`, in every worktree, not just the one you're
  in.** A stash left by another session or a different worktree of the same clone sits at
  `stash@{0}` until something pops or drops it.
- **If a pop applied the wrong thing:** capture your own in-flight diff first
  (`git diff -- <file-you-meant>`), then `git reset --hard HEAD` — safe, it only discards the
  working tree/index, never a stash object — then `git apply` your captured diff back. Confirm
  with `git stash list` before and after: the stack should show the same entries in the same
  positions, untouched.
- Broader than `stash`: reflog and any hook installed at the `.git` level are the same
  shared-across-worktrees shape; only `stash pop` has been hit here.
