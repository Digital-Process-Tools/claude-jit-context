---
description: Diagnose jit-context -- is any of this running at all, and against which tree?
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh:*)
---

Run the diagnostic and relay its output verbatim:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh --arguments-string '$ARGUMENTS'
```

**The whole typed `$ARGUMENTS` string is handed through one synthetic `--arguments-string`
flag, rather than split here in the command body (#439).** A bare `allowed-tools: Bash`
grants every shell command the directory holds as unrestricted access; narrowing it to one
script only works if the literal command text Claude is about to run is, byte for byte, the
exact script invocation the grant names, with no unresolved shell syntax left anywhere in
it. The previous body wrapped the whole thing in an explicit `bash -c '...'` to force the
`read -a` splitting in #405 into a real bash regardless of what shell ran this fenced body
-- but that made the body's first word `bash -c`, not the script, so no scoped grant could
ever match it. `jit-doctor.sh` already does its own flag parsing (`--base`'s own `case`
arm); it now does the splitting too, under the bash it always runs under, so the grant
above can name it directly.

**This is NOT the same substitution the previous body relied on, and the difference is why
this fix works at all.** The previous body used `"${ARGUMENTS:-}"` (braced, with a default),
which Claude Code never substitutes -- it stays literal shell syntax that only a real shell
evaluates at runtime, against an actual value Claude Code supplies out of band. Verified
against a real `claude -p` run with a narrowed grant and no `--dangerously-skip-permissions`:
a command whose literal text still contains unresolved shell syntax like `${...}` or `$?` is
held for approval regardless of whether it matches the grant's own prefix -- "Contains
expansion", the Bash tool's own name for it -- so `"${ARGUMENTS:-}"` would have denied EVERY
invocation, typed arguments or none, defeating this fix's purpose outright. The bare,
unbraced `$ARGUMENTS` above is different: Claude Code substitutes it with the raw typed
text *before* the command ever reaches the shell or the permission check, the same way it
already substitutes `${CLAUDE_PLUGIN_ROOT}` -- so by the time the grant is checked, the
quotes around it hold a plain literal string, not open shell syntax.

`${CLAUDE_PLUGIN_ROOT}` is what makes this reachable without a version number: the only
other way to run this tool is `bash ~/.claude/plugins/cache/dpt-plugins/jit-context/<version>/scripts/jit-doctor.sh`,
and that path changes on every plugin update (#202). `hooks/hooks.json` already resolves
every hook the same way; this is the same resolution, for the one diagnostic you reach for
when you suspect nothing is firing and do not yet know why.

`jit-doctor.sh` parses `--base <tree>` as two separate words (the `--base)` arm in its own
argument loop), so `$ARGUMENTS` is genuinely meant to carry more than one shell word here --
a plain, UNQUOTED `$ARGUMENTS` would word-split and glob-expand before the script ever saw
it (#278). The body above passes the whole substituted string as ONE quoted argument to
`--arguments-string` instead; `jit-doctor.sh` then builds the array itself with `read -a`,
which splits that one argument on spaces and never globs.

**A typed value containing a literal single-quote is not defended against here, and this is
a real trade against #278's own original fix -- read the whole of this section before
assuming it is small.** The body quotes `$ARGUMENTS` with single quotes rather than double
(`'$ARGUMENTS'`): a first attempt used double quotes, and a real `claude -p` run showed
that was not merely imprecise but actively dangerous -- bash still expands
`$(...)`, backticks and `$VAR` *inside* double quotes, with no `"` needed at all. Confirmed
by typing `--base foo $(touch /tmp/pwned)`: Claude Code substitutes `$ARGUMENTS` with that
raw text before the shell ever parses it, so the resulting line read `--arguments-string
"--base foo $(touch /tmp/pwned)"` and the `$(...)` ran as a live command substitution with
no quote-breakout required -- this is full, unscoped shell execution, not the narrow
quote-escape #278 itself accepted. Single quotes close this and the double-quote-breakout
case both: bash performs **zero** expansion inside single quotes, so `$(...)`, backticks,
`$VAR` and `"` are all inert there. The one character still live is a literal `'` itself,
which can still close the quotes early and splice a second command -- confirmed the same
way, with `--base foo' ; touch /tmp/pwned ; echo '`.

**Whether that one remaining character is actually caught at runtime is not something this
fix controls, and saying otherwise would overstate it.** Three different things were
observed to intervene across testing, none of them a property of this command's own code:
Claude Code's own permission layer held a command containing unresolved `${...}` or `$?`
syntax for approval regardless of grant ("Contains expansion"); a sandboxed test
environment's own file-write restrictions separately caught a `$(touch ...)` writing outside
an allowed directory; and, observed directly, an agent presented with a `'`-breakout
argument sometimes recognized the shape as an injection attempt and refused to run it
rather than relaying it verbatim, which is a judgment call a differently-phrased prompt may
not trigger. None of this is a structural guarantee against the single-quote case, which is
why it stays documented as a real, open residual. #278's own `"${ARGUMENTS:-}"` design closed
every one of these by never splicing raw text into the command at all -- but that design is
the one a narrowed grant always denies (above), which is the actual tension at the center of
this issue: the injection-proof mechanism and a narrowed `allowed-tools` grant cannot both be
had at once under Claude Code's current permission model. This is bounded the same way #278
itself bounded its own, narrower case ("the invoking user's own typed text, on their own
machine") -- a user splicing a command into their own typed argument on their own machine --
but it is a materially larger bound than #278's: that one could at worst splice stray
filenames as extra arguments, this one is unscoped shell execution for the one character
that still breaks out.

Do not summarise away any line -- relay the report exactly as printed, including its blank
lines and its section headers. Three outcomes, and only the report itself carries which one
this run reached:

- **exit 0, "nothing inert"** -- every ADVISORY finding still lands in the output; read them,
  do not drop them because the run was clean.
- **exit 1** -- a layer holds `.md` entries and no `00-index.tsv` beside them, so the matcher
  can never load them. This is a defect in the tree, not in the diagnostic.
- **exit 2, `SKIPPED`** -- the tree could not be evaluated at all. This is not a clean
  result and must never be relayed as one; the reason is named on stderr.

The line worth reading before any other: **`which copy runs`**, under `hooks`. `cannot tell`
is a real, first-class answer -- not a failure of the diagnostic -- because Claude Code
merges settings from places a script cannot enumerate. Never restate `cannot tell` as
"nothing is registered"; those are different claims and the report says so.

If the report names more than one plugin cache copy under `plugin copy`, that is #189's own
finding: which one loads is not decidable from here, and the diagnostic says so rather than
guessing. Do not pick one and report it as the answer.
