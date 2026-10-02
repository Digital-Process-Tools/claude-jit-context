---
description: Diagnose claude-jit-context -- is any of this running at all, and against which tree?
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh:*)
---

Run the diagnostic and relay its output verbatim:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh --arguments-string "$ARGUMENTS"
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
other way to run this tool is `bash ~/.claude/plugins/cache/dpt-plugins/claude-jit-context/<version>/scripts/jit-doctor.sh`,
and that path changes on every plugin update (#202). `hooks/hooks.json` already resolves
every hook the same way; this is the same resolution, for the one diagnostic you reach for
when you suspect nothing is firing and do not yet know why.

`jit-doctor.sh` parses `--base <tree>` as two separate words (the `--base)` arm in its own
argument loop), so `$ARGUMENTS` is genuinely meant to carry more than one shell word here --
a plain, UNQUOTED `$ARGUMENTS` would word-split and glob-expand before the script ever saw
it (#278). The body above passes the whole substituted string as ONE quoted argument to
`--arguments-string` instead; `jit-doctor.sh` then builds the array itself with `read -a`,
which splits that one argument on spaces and never globs.

**A typed value containing a literal double-quote is not defended against here, and this is
a real, narrower trade against #278's own original fix.** Because `$ARGUMENTS` is
substituted into the body as raw text before the shell parses anything, a `"` inside a typed
`--base` value can close the quotes early and splice in a second shell command -- confirmed
against a real `claude -p` run with `--base foo" ; echo INJECTED #`, where the resulting
line read `--arguments-string "--base foo" ; echo INJECTED #"` and the second `; echo`
became genuine shell syntax rather than argument text. #278's own `"${ARGUMENTS:-}"` design
closed exactly this by never splicing raw text into the command at all -- but that design is
the one a narrowed grant always denies (above). This bound matches the one #278 itself
already accepted for the unquoted case ("the value is the invoking user's own typed text, on
their own machine"), narrowed further here to one character, and is filed rather than
blocking this fix on the same precedent.

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
