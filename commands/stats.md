---
description: What fired this session, on what word, and what it cost -- the detail the Stop line's one-line total points at.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-stats.sh":*)
---

Run the report and relay its output verbatim:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-stats.sh" --arguments-string '$ARGUMENTS'
```

`${CLAUDE_PLUGIN_ROOT}` is the same resolution `commands/doctor.md` and `commands/init.md`
use, for the same reason (#202): the only other route to this script is a plugin-cache path
that changes on every update.

`jit-stats.sh` parses `--base <tree>` and `--misses-top <n>` the same way `jit-doctor.sh`
parses `--base` -- two separate words -- so `$ARGUMENTS` genuinely carries more than one
shell word here. The body above passes the whole substituted string as ONE quoted argument
to a synthetic `--arguments-string` flag rather than splitting it here (#439): a bare
`allowed-tools: Bash` grants every shell command, and narrowing it to one script only works
if the literal command text Claude is about to run is, byte for byte, the exact script
invocation the grant names -- the previous body wrapped everything in an explicit
`bash -c '...'`, which made the body's first word `bash -c`, not the script, so no scoped
grant could ever match it. `jit-stats.sh` now builds the array itself with `read -a`, which
splits that one argument on spaces and never globs. **`commands/doctor.md` carries the full
explanation of why this had to be the bare, unbraced `$ARGUMENTS` (Claude Code's own
pre-substitution) rather than the previous `"${ARGUMENTS:-}"` (a real shell's own runtime
expansion, which a narrowed grant always denies, verified against a real `claude -p` run) --
read it there once rather than three times, including the one trade-off it documents: a
typed value containing a literal single-quote is not defended against here -- a `$(...)` or
backtick needs no quote-breakout at all under the double-quoted design this diff tried and
rejected after a real exploit confirmed it, which is why single quotes are used instead --
bounded the same way #278 itself already bounded the unquoted case, though wider in effect
since it reaches unscoped shell execution rather than stray arguments.**

**The `read -a` now runs inside `jit-stats.sh` itself, which always runs under a real bash,
not in whatever shell runs this command body (#405).** `read -a` is a bash-only spelling of
the builtin -- zsh spells it `read -A` and errors `bad option: -a` on the bash form -- and a
slash command's fenced `bash` body is not guaranteed to run under bash. Before the #405 fix,
that error left the split array unset and the script ran with **no arguments at all**: a
typed `--misses-top 30` or `--base <tree>` was silently dropped rather than reaching the
script, which then produced a plausible report answering a different question than the one
asked. Invoking `bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-stats.sh` explicitly, as the body
above does, guarantees the script itself -- and therefore the `read -a` inside it -- always
runs under bash regardless of what shell is running this fenced body.

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
