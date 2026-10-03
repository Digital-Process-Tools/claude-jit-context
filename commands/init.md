---
description: Seed .claude/jit-context with one live entry that says how to write the next one
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-init.sh":*)
---

Run the seeder and relay its output verbatim:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-init.sh" --arguments-string '$ARGUMENTS'
```

**The whole typed `$ARGUMENTS` string is handed through one synthetic `--arguments-string`
flag, rather than split here in the command body (#439).** A bare `allowed-tools: Bash`
grants every shell command the directory holds as unrestricted access; narrowing it to one
script only works if the literal command text Claude is about to run is, byte for byte, the
exact script invocation the grant names, with no unresolved shell syntax left anywhere in
it. The previous body wrapped the whole thing in an explicit `bash -c '...'` to force the
`read -a` splitting in #405 into a real bash regardless of what shell ran this fenced body
-- but that made the body's first word `bash -c`, not the script, so no scoped grant could
ever match it. `jit-init.sh` already does its own flag parsing (`--base`'s own `case` arm);
it now does the splitting too, under the bash it always runs under, so the grant above can
name it directly. **`commands/doctor.md` carries the full explanation of why this had to be
the bare, unbraced `$ARGUMENTS` (Claude Code's own pre-substitution) rather than the
previous `"${ARGUMENTS:-}"` (a real shell's own runtime expansion, which a narrowed grant
always denies) -- read it there once rather than three times.**

`${CLAUDE_PLUGIN_ROOT}` is the same resolution `commands/doctor.md` uses, for the same
reason (#202): after a marketplace install there is no other reachable path to
`jit-init.sh` from a user's own shell.

`jit-init.sh` parses `--base <project>/.claude/jit-context` as two separate words (the
`--base)` arm in its own argument loop), so `$ARGUMENTS` is genuinely meant to carry more
than one shell word here -- a plain, UNQUOTED `$ARGUMENTS` would word-split and glob-expand
before the script ever saw it (#278). The body above passes the whole substituted string as
ONE quoted argument to `--arguments-string` instead; `jit-init.sh` then builds the array
itself with `read -a`, which splits that one argument on spaces and never globs.

**A typed value containing a literal single-quote is not defended against here** -- read
`commands/doctor.md`'s full account, which also explains why the body quotes `$ARGUMENTS`
with single quotes rather than double: a `$(...)` or backtick inside a typed value runs
regardless of quoting style unless single quotes (which disable all expansion) are used,
and this was confirmed with a real exploit against the double-quoted draft before it shipped.
The one character still live, `'`, is bounded the same way #278 itself already bounded the
unquoted case -- the invoking user's own typed text, on their own machine -- but is a wider
bound than #278's own, since it reaches unscoped shell execution rather than stray
arguments.

A second run over an already-seeded project **refuses rather than overwrites**, exits `1`,
and names the file it left alone -- a copy you have since edited is not ours to replace.
Relay that refusal verbatim too; it is not a failure of this command.
