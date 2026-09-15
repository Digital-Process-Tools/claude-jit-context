---
description: What fired this session, on what word, and what it cost -- the detail the Stop line's one-line total points at.
allowed-tools: Bash
---

Run the report and relay its output verbatim:

```bash
IFS=' ' read -r -a jit_stats_args <<< "${ARGUMENTS:-}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-stats.sh" ${jit_stats_args[@]+"${jit_stats_args[@]}"}
```

`${CLAUDE_PLUGIN_ROOT}` is the same resolution `commands/doctor.md` and `commands/init.md`
use, for the same reason (#202): the only other route to this script is a plugin-cache path
that changes on every update.

`jit-stats.sh` parses `--base <tree>` and `--misses-top <n>` the same way `jit-doctor.sh`
parses `--base` -- two separate words -- so `$ARGUMENTS` genuinely carries more than one
shell word here, and the `read -a` above makes that splitting explicit rather than leaning
on bash's own unquoted-expansion word-splitting (#278).

Do not summarise away any line -- relay the report exactly as printed. Three outcomes:

- **exit 0** -- a report was produced. It may say "nothing fired for this session key" if
  nothing has, which is not a failure of the tool.
- **exit 1** -- the tree exists but no session state could be found at all: nothing has
  fired yet, anywhere, this session.
- **exit 2** -- could not evaluate: no jit-context tree, or a bad argument.

**The session it reports on is a heuristic, and the report says so on its own first line.**
A slash command's own bash body never receives the JSON payload a hook gets, so there is no
true session id to key on here -- this picks the most recently written marker file under
`.discovery/state/` and reports its session suffix. On a checkout with one active session
this is exactly right; on a checkout with several concurrent sessions it can name the wrong
one. Never read its `session key:` line as a certainty stronger than the line itself claims.

**The word or pattern that matched each entry is read back out of `hooks.log`**, not out of
the marker files -- the marker files were never asked to carry it, and it is a best-effort
correlation for the same reason the session key is: `hooks.log` carries no session id
column either. It searches for `<layer>:<file>(` as one unit, not the file name alone, so
it cannot be fooled by an unrelated entry from a DIFFERENT layer that happens to share a
file name -- but it still has no session id to anchor on, so a blank `matched=` is not
evidence the entry did not fire; it is evidence this correlation could not find the line.
