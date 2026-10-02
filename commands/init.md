---
description: Seed .claude/jit-context with one live entry that says how to write the next one
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-init.sh:*)
---

Run the seeder and relay its output verbatim:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-init.sh --arguments-string "${ARGUMENTS:-}"
```

**The whole typed `$ARGUMENTS` string is handed through one synthetic `--arguments-string`
flag, rather than split here in the command body (#439).** A bare `allowed-tools: Bash`
grants every shell command the directory holds as unrestricted access; narrowing it to one
script only works if the body's own first words are that exact script invocation. The
previous body wrapped the whole thing in an explicit `bash -c '...'` to force the `read -a`
splitting in #405 into a real bash regardless of what shell ran this fenced body -- but that
made the body's first word `bash -c`, not the script, so no grant could ever name just this
script. `jit-init.sh` already does its own flag parsing (`--base`'s own `case` arm); it now
does the splitting too, under the bash it always runs under, so the grant above can name it
directly.

`${CLAUDE_PLUGIN_ROOT}` is the same resolution `commands/doctor.md` uses, for the same
reason (#202): after a marketplace install there is no other reachable path to
`jit-init.sh` from a user's own shell.

`jit-init.sh` parses `--base <project>/.claude/jit-context` as two separate words (the
`--base)` arm in its own argument loop), so `$ARGUMENTS` is genuinely meant to carry more
than one shell word here -- a plain `"$ARGUMENTS"` would hand the script one combined
argument and break `--base`. The body above passes the whole string as ONE quoted argument
to `--arguments-string` precisely so nothing splits or globs it before the script sees it;
`jit-init.sh` then builds the array itself with `read -a`, which splits on spaces and never
globs. Quoting it here is what keeps a typed value containing `*` or `?` from matching
whatever files sat in the current directory and splicing in as extra arguments, silently and
differently on every machine (#278).

A second run over an already-seeded project **refuses rather than overwrites**, exits `1`,
and names the file it left alone -- a copy you have since edited is not ours to replace.
Relay that refusal verbatim too; it is not a failure of this command.
